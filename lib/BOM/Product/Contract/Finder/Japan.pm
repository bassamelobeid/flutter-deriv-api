package BOM::Product::Contract::Finder::Japan;
use strict;
use warnings;
use Date::Utility;
use Time::Duration::Concise;
use LandingCompany::Offerings qw(get_offerings_flyby);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Runtime;
use BOM::Product::Contract::Category;
use BOM::System::Chronicle;
use Format::Util::Numbers qw(roundnear);
use List::Util qw(reduce);
use Exporter qw( import );
our @EXPORT_OK = qw(available_contracts_for_symbol);
use Math::CDF qw(qnorm);

use BOM::Product::Contract::PredefinedParameters qw(get_predefined_offerings);

=head1 available_contracts_for_symbol

Returns a set of available contracts for a particular contract which included predefined trading period and 20 predefined barriers associated with the trading period

=cut

sub available_contracts_for_symbol {
    my $args         = shift;
    my $symbol       = $args->{symbol} || die 'no symbol';
    my $underlying   = create_underlying($symbol);
    my $now          = $args->{date} || Date::Utility->new;
    my $current_tick = $args->{current_tick} // $underlying->spot_tick // $underlying->tick_at($now->epoch, {allow_inconsistent => 1});

    my $calendar = $underlying->calendar;
    my ($open, $close, @offerings);
    if ($calendar->trades_on($now)) {
        $open      = $calendar->opening_on($now)->epoch;
        $close     = $calendar->closing_on($now)->epoch;
        @offerings = get_predefined_offerings($underlying);
        foreach my $offering (@offerings) {
            my @expired_barriers = ();
            if ($offering->{barrier_category} eq 'american') {
                my ($high, $low);
                if ($underlying->for_date) {
                    # for historical access, we fetch ohlc directly from the database
                    ($high, $low) = @{
                        $underlying->get_high_low_for_period({
                                start => $date_start,
                                end   => $for_date
                            })}{'high', 'low'};
                } else {
                    my $highlow_key = join '_', ('highlow', $underlying->symbol, $date_start, $date_expiry);
                    my $cache = BOM::System::Chronicle::get_chronicle_reader->get($cache_namespace, $highlow_key);
                    if ($cache) {
                        ($high, $low) = ($cache->[0], $cache->[1]);
                    }
                }

                foreach my $barrier (@{$offering->{available_barriers}}) {
                    # for double barrier contracts, $barrier is [high, low]
                    if (ref $barrier eq 'ARRAY' and ($high > $barrier->[0] or $low < $barrier->[1])) {
                        push @expired_barriers, $barrier;
                    } elsif ($high > $barrier or $low < $barrier) {
                        push @expired_barriers, $barrier;
                    }
                }
            }
            $offering->{expired_barriers} = \@expired_barriers;
        }
    }

    return {
        available    => \@offerings,
        hit_count    => scalar(@offerings),
        open         => $open,
        close        => $close,
        feed_license => $underlying->feed_license
    };
}

# this is purely for testability
sub get_offerings {
    my $symbol = shift;

    my $flyby = get_offerings_flyby(BOM::Platform::Runtime->instance->get_offerings_config, 'japan');

    my %similar_args = (
        underlying_symbol => $symbol,
        start_type        => 'spot',
    );

    my @offerings = $flyby->query({
        expiry_type       => 'daily',
        barrier_category  => 'euro_non_atm',
        contract_category => 'endsinout',
        %similar_args,
    });

    push @offerings,
        $flyby->query({
            expiry_type       => ['daily', 'intraday'],
            barrier_category  => 'euro_non_atm',
            contract_category => 'callput',
            %similar_args,
        });

    push @offerings,
        $flyby->query({
            expiry_type       => 'daily',
            barrier_category  => 'american',
            contract_category => ['touchnotouch', 'staysinout'],
            %similar_args,
        });

    return map { $_->{barriers} = BOM::Product::Contract::Category->new($_->{contract_category})->two_barriers ? 2 : 1; $_ } @offerings;
}

=head2 _apply_trading_periods_to_offerings

We set the predefined trading periods based on Japan requirement:
Intraday contract:
1) Start at 15 min before closest even hour and expires with duration of 2 hours and 15 min.
   Mon-Friday
   00:00-02:00, 01:45-04:00, 03:45-06:00, 05:45-08:00, 0745-10:00,09:45-12:00, 11:45-14:00, 13:45-16:00, 15:45-18:00 <break>23:45-02:00, 01:45-04:00, 

   For AUDJPY,USDJPY,AUDUSD, it will be 
    00:00-02:00,01:45-04:00, 03:45-06:00, 05:45-08:00, 0745-10:00,09:45-12:00, 11:45-14:00, 13:45-16:00, 15:45-18:00<break> 21:45:00 -23:59:59, 23:45-02:00,01:45-04:00, 03:45-06:00


3) Start at 00:45 and expires with durarion of 5 hours and 15 min and spaces the next available trading window by 4 hours.
   Example: 00:45-06:00 ; 04:45-10:00 ; 08:45-14:00 ; 12:45-18:00


Daily contract:
1) Daily contract: Start at 00:00GMT and end at 23:59:59GMT of the day
2) Weekly contract: Start at 00:00GMT first trading day of the week and end at the close of last trading day of the week
3) Monthly contract: Start at 00:00GMT of the first trading day of the calendar month and end at the close of the last trading day of the month
4) Quarterly contract: Start at 00:00GMT of the first trading day of the quarter and end at the close of the last trading day of the quarter.

=cut

my $cache_keyspace = 'FINDER_PREDEFINED_SET';
my $cache_sep      = '==';

sub _apply_trading_periods_to_offerings {
    my ($symbol, $now, $offerings) = @_;

    my $trading_periods = get_trading_periods($symbol, $now);

    return () unless @$trading_periods;

    my $underlying  = create_underlying($symbol);
    my $close_epoch = $underlying->calendar->closing_on($now)->epoch;
    # full trading seconds
    my $trading_seconds = $close_epoch - $now->truncate_to_day->epoch;

    my @new_offerings;
    foreach my $o (@$offerings) {
        # we offer 0 day (end of day) and intraday durations to callput only
        my $minimum_contract_duration;
        if ($o->{contract_category} ne 'callput') {
            $minimum_contract_duration = 86400;
        } else {
            $minimum_contract_duration =
                $o->{expiry_type} eq 'intraday' ? Time::Duration::Concise->new({interval => $o->{min_contract_duration}})->seconds : $trading_seconds;
        }

        my $maximum_contract_duration =
            ($o->{contract_category} eq 'callput' and $o->{expiry_type} eq 'intraday')
            ? 21600
            : Time::Duration::Concise->new({interval => $o->{max_contract_duration}})->seconds;

        foreach my $trading_period (grep { defined } @$trading_periods) {
            my $date_expiry      = $trading_period->{date_expiry}->{epoch};
            my $date_start       = $trading_period->{date_start}->{epoch};
            my $trading_duration = $date_expiry - $date_start;
            if ($trading_duration < $minimum_contract_duration or $trading_duration > $maximum_contract_duration) {
                next;
            } elsif ($now->day_of_week == 5
                and $trading_duration < 86400
                and ($date_expiry > $close_epoch or $date_start > $close_epoch))
            {
                next;
            } else {
                push @new_offerings, +{%{$o}, trading_period => $trading_period};
            }
        }

    }

    return @new_offerings;
}

=head2 _set_predefined_barriers

To set the predefined barriers on each trading period.
We do a binary search to find out the boundaries barriers associated with theo_prob [0.02,0.98] of a digital call,
then split into 20 barriers that within this boundaries. The barriers will be split in the way more cluster towards current spot and gradually spread out from current spot.

=cut

sub _set_predefined_barriers {
    my $args = shift;
    my ($underlying, $contract, $current_tick, $now) = @{$args}{'underlying', 'contract', 'current_tick', 'date'};

    my $trading_period     = $contract->{trading_period};
    my $date_start         = $trading_period->{date_start}->{epoch};
    my $date_expiry        = $trading_period->{date_expiry}->{epoch};
    my $duration           = $trading_period->{duration};
    my $barrier_key        = join($cache_sep, $underlying->symbol, $date_start, $date_expiry);
    my $available_barriers = BOM::System::RedisReplicated::redis_read->get($cache_keyspace . '::' . $barrier_key);
    my $current_tick_quote = $current_tick->quote;
    if (not $available_barriers) {
        my $start_tick = $underlying->tick_at($date_start) // $current_tick;
        my @boundaries_barrier = map {
            _get_strike_from_call_bs_price({
                call_price => $_,
                timeinyear => ($date_expiry - $date_start) / (365 * 86400),
                start_tick => $start_tick->quote,
                vol        => 0.1,
            });
        } qw(0.02 0.98);
        $available_barriers = _split_boundaries_barriers({
            pip_size           => $underlying->pip_size,
            start_tick         => $start_tick->quote,
            boundaries_barrier => \@boundaries_barrier
        });

        # Expires at the end of the available period.
        # The shortest duration is 2h15m. So make refresh the barriers cache at this time
        BOM::System::RedisReplicated::redis_write->set($cache_keyspace . '::' . $barrier_key, $available_barriers, 'PX', 8100);
    }

    my $expired_barriers = _get_expired_barriers({
        available_barriers => $available_barriers,
        start              => $date_start,
        expiry             => $date_expiry,
        now                => $now->epoch,
        underlying         => $underlying
    });

    if ($contract->{barriers} == 1) {
        my @barriers = sort { $a <=> $b } values %$available_barriers;

        $contract->{expired_barriers}   = $contract->{barrier_category} ne 'american' ? [] : $expired_barriers;
        $contract->{available_barriers} = \@barriers;
        $contract->{barrier}            = reduce { abs($current_tick->quote - $a) < abs($current_tick->quote - $b) ? $a : $b } @barriers;
    } elsif ($contract->{barriers} == 2) {
        ($contract->{available_barriers}, $contract->{expired_barriers}) = _get_barriers_pair({
            contract_category  => $contract->{contract_category},
            available_barriers => $available_barriers,
            expired_barriers   => $expired_barriers,
        });

    }

    return;
}

=head2 _get_expired_barriers

- To check is any of our available barriers is expired
- reset the redis cache if there is new expired barriers

=cut

sub _get_expired_barriers {
    my $args = shift;

    my $available_barriers   = $args->{available_barriers};
    my $date_start           = $args->{start};
    my $date_expiry          = $args->{expiry};
    my $now                  = $args->{now};
    my $underlying           = $args->{underlying};
    my $expired_barriers_key = join($cache_sep, $underlying->symbol, 'expired_barrier', $date_start, $date_expiry);
    my $expired_barriers     = BOM::System::RedisReplicated::redis_read->get($cache_keyspace . '::' . $expired_barriers_key);
    my $high_low_key         = join($cache_sep, $underlying->symbol, 'high_low', $date_start, $now);
    my $high_low             = BOM::System::RedisReplicated::redis_read->get($cache_keyspace . '::' . $high_low_key);
    if (not $high_low) {
        $high_low = $underlying->get_high_low_for_period({
            start => $date_start,
            end   => $now,
        });

        BOM::System::RedisReplicated::redis_write->set($cache_keyspace . '::' . $high_low_key, $high_low, 'PX', 10);
    }

    my $high                      = $high_low->{high};
    my $low                       = $high_low->{low};
    my @barriers                  = sort { $a <=> $b } values %$available_barriers;
    my %skip_list                 = map { $_ => 1 } (@$expired_barriers);
    my @unexpired_barriers        = grep { !$skip_list{$_} } @barriers;
    my $new_added_expired_barrier = 0;

    if (defined $high and defined $low) {
        foreach my $barrier (@unexpired_barriers) {
            if ($barrier < $high && $barrier > $low) {
                push @$expired_barriers, $barrier;
                $new_added_expired_barrier++;
            }
        }
    }
    if ($new_added_expired_barrier > 0) {
        BOM::System::RedisReplicated::redis_write->set($cache_keyspace . '::' . $expired_barriers_key, $expired_barriers, 'PX', 8100);
    }

    return $expired_barriers;

}

=head2 _get_barriers_pair

- For staysinout contract, we need to pair the barriers symmetry, ie (42, 58), (34,66), (26,74), (18,82) 
- For endsinout contract, we need to pair barriers as follow: (42,58), (34,50), (50,66), (26,42), (58,74), (18,34), (66,82), (2, 26), (74, 98)

Note: 42 is -8d from the spot at start and 58 is +8d from spot at start
where d is the minimum increment that determine by divided the distance of boundaries by 96 (48 each side) 


=cut

sub _get_barriers_pair {
    my $args = shift;

    my $contract_category        = $args->{contract_category};
    my $available_barriers       = $args->{available_barriers};
    my $list_of_expired_barriers = $args->{expired_barriers};
    my @barrier_pairs =
        $contract_category eq 'staysinout'
        ? ([42, 58], [34, 66], [26, 74], [18, 82])
        : ([42, 58], [34, 50], [50, 66], [26, 42], [58, 74], [18, 34], [66, 82], [2, 26], [74, 98]);
    my @barriers;
    my @expired_barriers;
    for my $pair (@barrier_pairs) {
        my ($barrier_low, $barrier_high) = @$pair;
        my $first_barrier  = $available_barriers->{$barrier_low};
        my $second_barrier = $available_barriers->{$barrier_high};

        if ($contract_category eq 'staysinout') {
            push @expired_barriers, [$first_barrier, $second_barrier]
                if (grep { $_ eq $first_barrier or $_ eq $second_barrier } @$list_of_expired_barriers);

        }
        push @barriers, [$first_barrier, $second_barrier];
    }

    return (\@barriers, \@expired_barriers);
}

=head2 _split_boundaries_barriers

-Split the boundaries barriers into 10 barriers by divided the distance of boundaries by 96 (48 each side) - to be used as increment.
The barriers will be split in the way more cluster towards current spot and gradually spread out from current spot.
- Included entry spot as well

=cut

sub _split_boundaries_barriers {
    my $args = shift;

    my $pip_size                    = $args->{pip_size};
    my $spot_at_start               = $args->{start_tick};
    my @boundaries_barrier          = @{$args->{boundaries_barrier}};
    my $distance_between_boundaries = abs($boundaries_barrier[0] - $boundaries_barrier[1]);
    my @steps                       = (8, 16, 24, 32, 48);
    my $minimum_step                = roundnear($pip_size, $distance_between_boundaries / ($steps[-1] * 2));
    my %barriers                    = map { (50 - $_ => $spot_at_start - $_ * $minimum_step, 50 + $_ => $spot_at_start + $_ * $minimum_step) } @steps;
    $barriers{50} = $spot_at_start;
    return \%barriers;
}

=head2 _get_strike_from_call_bs_price

To get the strike that associated with a given call bs price.

=cut

sub _get_strike_from_call_bs_price {
    my $args = shift;

    my ($call_price, $T, $spot, $vol) =
        @{$args}{'call_price', 'timeinyear', 'start_tick', 'vol'};
    my $q  = 0;
    my $r  = 0;
    my $d2 = qnorm($call_price * exp($r * $T));
    my $d1 = $d2 + $vol * sqrt($T);

    my $strike = $spot / exp($d1 * $vol * sqrt($T) - ($r - $q + ($vol * $vol) / 2) * $T);
    return $strike;
}

1;
