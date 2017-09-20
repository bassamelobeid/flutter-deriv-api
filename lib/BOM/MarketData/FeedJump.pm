package BOM::MarketData::FeedJump;

use strict;
use warnings;

use Moo;

use Mojo::Redis2;
use BOM::Platform::QuantsConfig;
use BOM::Platform::Chronicle;
use Quant::Framework::EconomicEventCalendar;
use BOM::MarketData qw(create_underlying_db);

use Try::Tiny;
use namespace::autoclean;
use JSON qw(from_json);
use List::Util qw(first);

has _eec                      => (is => 'rw');
has _symbols_to_perform_check => (is => 'rw');

has _jump_threshold => (
    is      => 'ro',
    default => 0.0005,
);

sub BUILD {
    my $self = shift;

    my $eec = Quant::Framework::EconomicEventCalendar->new(
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
    );
    $self->_eec($eec);

    my %symbols = map { $_ => 1 } create_underlying_db->symbols_for_intraday_fx;
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
                $self->_perform_checks(from_json($tick));
            }
            catch {
                warn "exception caught while performing feed jump checks for $_";
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
                    # each jump triggers a commission for 20 minutes because historical volatility is calculated using the last 20 minutes ticks
                    end_time   => $tick->{epoch} + 20 * 60,
                    partitions => [{
                            partition_range => $partition_range,
                            flat            => 0,
                            cap_rate        => 0.3,
                            floor_rate      => 0.05,
                            width           => 0.5,
                            centre_offset   => 0,
                        }
                    ],
                });
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
        if ($cache{events} && time - 5 * 60 < $cache{epoch}) {
            $events = $cache{events};
        } else {
            my $quotes = $self->_last_5_quotes->{$underlying_symbol} // [];
            # if we don't have 5 ticks, then look back 10 seconds
            my $from = @$quotes == 5 ? $quotes->[0]->{epoch} : $epoch - 10;
            my $e = $self->_eec->get_latest_events_for_period({
                from => $from,
                to   => $epoch
            });
            $events = $cache{events} = $e;
            $cache{epoch} = time;

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
