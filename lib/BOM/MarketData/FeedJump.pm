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

use Mojo::Redis2;
use BOM::Platform::QuantsConfig;
use BOM::Platform::Chronicle;
use Quant::Framework::EconomicEventCalendar;
use LandingCompany::Offerings qw(get_offerings_flyby);

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
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
    );
    $self->_eec($eec);

    # we are only concern about the 9 forex pairs where we offer multi-barrier trading on.
    my $fb = get_offerings_flyby(BOM::Platform::Runtime->instance->get_offerings_config, 'japan');
    my %symbols = map { $_ => 1 } $fb->values_for_key('underlying_symbol');
    $self->_symbols_to_perform_check(\%symbols);

    return;
}

sub run {
    my $self = shift;

    print "starting feed-jump\n";
    return $self->iterate;
}

sub iterate {
    my $self = shift;

    my $redis = Mojo::Redis2->new({url => $ENV{REDIS_CACHE_SERVER} // 'redis://127.0.0.1'});

    # Set up the handler to be called on each Redis published quote notification
    $redis->on(
        pmessage => sub {
            my ($redis, $tick) = @_;
            try {
                $self->_perform_checks($json->decode($tick));
            }
            catch {
                warn "exception caught while performing feed jump checks for $_";
                stats_inc('bom.marketdata.feedjump.exception');
            };
        });

    $redis->psubscribe(
        ['FEED_LATEST_TICK::*'],
        sub {
            my ($self, $err);
            warn "Had error when subscribing - $err" if $err;
            print "Subscribed and waiting for ticks\n";
        });

    Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

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
            my $partition_range = $self->_has_events_for_last_5_ticks($tick->{epoch}, $tick->{symbol}) ? '0-1' : '0.5-1';
            my $quants_config = BOM::Platform::QuantsConfig->new(
                chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
                chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
                recorded_date    => Date::Utility->new
            );
            $quants_config->save_config(
                'commission',
                +{
                    name              => "feed jump $tick->{symbol} $tick->{epoch}",
                    underlying_symbol => $tick->{symbol},
                    start_time        => $tick->{epoch},
                    # each jump triggers a commission for 10 minutes, also this is handled in historical volatility
                    end_time   => $tick->{epoch} + 10 * 60,
                    partitions => [{
                            partition_range => $partition_range,
                            flat            => 0,
                            cap_rate        => 0.05,
                            floor_rate      => 0,
                            width           => 0.5,
                            centre_offset   => 0,
                        }
                    ],
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
