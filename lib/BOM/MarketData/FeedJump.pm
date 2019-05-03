package BOM::MarketData::FeedJump;

use utf8;

=encoding UTF-8

=head1 NAME

BOM::MarketData::FeedJump

=head1 DESCRIPTION

This acts as a dæmon which runs continuously, monitoring the feed.

A jump is defined as a change in +/- 0.05% in the spot
price over the last 20 ticks.

When a jump is detected, we insert extra commission which will last for
20 minutes. This is intended to guard against market events that we don't
cover in the existing economic events.

=cut

use strict;
use warnings;

use Moo;

use BOM::Config::QuantsConfig;
use BOM::Config::Chronicle;
use BOM::Config::RedisReplicated;
use Quant::Framework::EconomicEventCalendar;
use LandingCompany::Registry;

use Try::Tiny;
use namespace::autoclean;
use JSON::MaybeXS;
use List::Util qw(first);
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);

has _eec                      => (is => 'rw');
has _symbols_to_perform_check => (is => 'rw');

has _jump_threshold => (
    is      => 'ro',
    default => 0.0005,
);

my $json = JSON::MaybeXS->new;

sub BUILD {
    my $self = shift;

    my $eec = Quant::Framework::EconomicEventCalendar->new(
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
    );
    $self->_eec($eec);

    # we are only concern about the 9 forex pairs where we offer multi-barrier trading on.
    my $offerings_obj = LandingCompany::Registry::get('svg')->multi_barrier_offerings(BOM::Config::Runtime->instance->get_offerings_config);
    my %symbols = map { $_ => 1 } $offerings_obj->values_for_key('underlying_symbol');
    $self->_symbols_to_perform_check(\%symbols);

    return;
}

sub run {
    my $self = shift;

    print "starting feed-jump\n";
    return $self->iterate;
}

sub iterate {
    my $self  = shift;
    my $redis = BOM::Config::RedisReplicated::redis_feed();

    $redis->subscription_loop(
        psubscribe       => ['FEED_LATEST_TICK::*'],
        default_callback => sub {
            my ($redis, $channel, $pattern, $message) = @_;
            try {
                $self->_perform_checks($json->decode($message));
            }
            catch {
                warn "exception caught while performing feed jump checks for $_";
                stats_inc('bom.marketdata.feedjump.exception');
            };
        });

    return;
}

sub _perform_checks {
    my ($self, $tick) = @_;

    return unless $self->_symbols_to_perform_check->{$tick->{symbol}};

    my $quotes = $self->_last_5_quotes->{$tick->{symbol}};

    if ($quotes && @$quotes == 5) {
        my $fraction = $tick->{quote} / $quotes->[0]->{quote};
        if ($fraction <= 1 - $self->_jump_threshold || $fraction >= 1 + $self->_jump_threshold) {
            # If sudden jump is caused by economic event, the we will add commission to ITM and OTM contracts.
            # Else we will just add commission to ITM contracts.
            my $quants_config = BOM::Config::QuantsConfig->new(
                chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
                chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
                recorded_date    => Date::Utility->new
            );
            $quants_config->save_config(
                'commission',
                +{
                    name              => "feed jump $tick->{symbol} $tick->{epoch}",
                    staff             => 'feed daemon',
                    underlying_symbol => $tick->{symbol},
                    start_time        => $tick->{epoch},
                    # each jump triggers a commission for 10 minutes, also this is handled in historical volatility
                    end_time => $tick->{epoch} + 10 * 60,
                    ITM_1    => 0.05,
                    ITM_2    => 0.05,
                    ITM_3    => 0.05,
                    ITM_max  => 0.05,
                });
            stats_inc('bom.marketdata.feedjump.commission.added', {tags => ['symbol:' . $tick->{symbol}]});
        }
    }

    $self->_add_quote_to_cache($tick);

    return;
}

{
    my %cache;
    # added cache so that we don't hit redis on every tick. 5-minute cache period
    # should be fine.
    sub _has_events_for_last_5_ticks {
        my ($self, $epoch, $underlying_symbol) = @_;

        my $events;
        my $start = Time::HiRes::time;
        if ($cache{events} && $start - 5 * 60 < $cache{epoch}) {
            $events = $cache{events};
            stats_inc('bom.marketdata.feedjump.events.cache.hit', {tags => ['symbol:' . $underlying_symbol]});
        } else {
            my $quotes = $self->_last_5_quotes->{$underlying_symbol} // [];
            # if we don't have 5 ticks, then look back 10 seconds
            my $from = @$quotes == 5 ? $quotes->[0]->{epoch} : $epoch - 10;
            my $e = $self->_eec->get_latest_events_for_period({
                from => $from,
                to   => $epoch
            });
            $events = $cache{events} = $e;
            $cache{epoch} = $start;
            my $elapsed = Time::HiRes::time - $start;
            stats_inc('bom.marketdata.feedjump.events.cache.miss', {tags => ['symbol:' . $underlying_symbol]});
            stats_timing('bom.marketdata.feedjump.events.cache.elapsed', int(1000.0 * $elapsed), {tags => ['symbol:' . $underlying_symbol]});
        }

        return first { $underlying_symbol =~ /$_->{symbol}/ && $_->{impact} > 1 } @$events;
    }
}

sub _add_quote_to_cache {
    my ($self, $tick) = @_;

    my $cache = $self->_last_5_quotes->{$tick->{symbol}} // [];

    unless (@$cache) {
        unshift @$cache, $tick;
        $self->_last_5_quotes->{$tick->{symbol}} = $cache;
        return;
    }

    unshift @$cache, $tick;
    @$cache = splice @$cache, 0, 5;

    return;
}

has _last_5_quotes => (
    is      => 'ro',
    default => sub { {} },
);

1;
