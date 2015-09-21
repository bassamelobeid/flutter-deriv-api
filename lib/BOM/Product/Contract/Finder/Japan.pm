package BOM::Product::Contract::Finder::Japan;
use strict;
use warnings;
use Date::Utility;
use Time::Duration::Concise;
use BOM::Product::Offerings;
use BOM::Market::Underlying;
use BOM::Product::Contract::Category;
use Format::Util::Numbers qw(roundnear);
use List::Util qw(reduce);
use base qw( Exporter );
use BOM::Product::ContractFactory qw(produce_contract);
our @EXPORT_OK = qw(available_contracts_for_symbol);
use Math::CDF qw(qnorm);

=head1 available_contracts_for_symbol

Returns a set of available contracts for a particular contract which included predefined trading period and 20 predefined barriers associated with the trading period

=cut

sub available_contracts_for_symbol {
    my $args         = shift;
    my $symbol       = $args->{symbol} || die 'no symbol';
    my $underlying   = BOM::Market::Underlying->new($symbol);
    my $now          = $args->{date} || Date::Utility->new;
    my $current_tick = $args->{current_tick} // $underlying->spot_tick // $underlying->tick_at($now->epoch, {allow_inconsistent => 1});

    my $exchange = $underlying->exchange;
    my ($open, $close);
    if ($exchange->trades_on($now)) {
        $open  = $exchange->opening_on($now)->epoch;
        $close = $exchange->closing_on($now)->epoch;
    }
    my $flyby     = BOM::Product::Offerings::get_offerings_flyby;
    my @offerings = $flyby->query({
            underlying_symbol => $symbol,
            start_type        => 'spot',
            expiry_type       => ['daily', 'intraday'],
            barrier_category  => ['euro_non_atm', 'american']});
    @offerings = _predefined_trading_period({
        offerings => \@offerings,
        exchange  => $exchange,
        date      => $now,
    });

    for my $o (@offerings) {
        my $cc = $o->{contract_category};
        my $bc = $o->{barrier_category};

        my $cat = BOM::Product::Contract::Category->new($cc);
        $o->{contract_category_display} = $cat->display_name;

        $o->{barriers} = $cat->two_barriers ? 2 : 1;

        _set_predefined_barriers({
            underlying   => $underlying,
            current_tick => $current_tick,
            contract     => $o,
            date         => $now,
        });

    }
    return {
        available => \@offerings,
        hit_count => scalar(@offerings),
        open      => $open,
        close     => $close,
    };
}

=head2 _predefined_trading_period

We set the predefined trading periods based on Japan requirement:
1) Start at 00:00GMT and expire with duration of 2, and 4 hours
2) Start at closest even hour and expire with duration of 2,and 4 hours. Example: Current hour is 3GMT, you will have trading period of 02-04GMT, 02-06GMT.
3) Start at 01:00GMT and expire with duration of 3, and 5 hours
4) Start at closest odd hour and expire with duration of 3,and 5 hours. Example: Current hour is 3GMT, you will have trading period of 03-06GMT, 03-08GMT.
5) Start at 00:00GMT and expire with duration of 1,2,3,7,30,60,180,365 days

=cut

my $cache_keyspace = 'FINDER_PREDEFINED_TRADING';
my $cache_sep      = '==';

sub _predefined_trading_period {
    my $args            = shift;
    my @offerings       = @{$args->{offerings}};
    my $exchange        = $args->{exchange};
    my $now             = $args->{date};
    my $now_hour        = $now->hour;
    my $now_minute      = $now->minute;
    my $now_date        = $now->date;
    my $trading_key     = join($cache_sep, $exchange->symbol, $now_date, $now_hour);
    my $today_close     = $exchange->closing_on($now)->epoch;
    my $trading_periods = Cache::RedisDB->get($cache_keyspace, $trading_key);
    if (not $trading_periods) {
        my $today        = $now->truncate_to_day;    # Start of the day object.
        my $start_of_day = $today->datetime;         # As a string.

        # Starting at midnight, running through these times.
        my @even_hourly_durations = qw(2h 4h);

        $trading_periods = [
            map {
                +{
                    date_start => {
                        date  => $start_of_day,
                        epoch => $today->epoch
                    },
                    date_expiry => {
                        date  => $_->datetime,
                        epoch => $_->epoch
                    },
                    duration => ($_->hour - $today->hour) . 'h'
                    }
                }
                grep {
                $now->is_before($_)
                } map {
                $today->plus_time_interval($_)
                } @even_hourly_durations
        ];

        # Starting at midnight, running through these dates.
        my @daily_durations = qw(1d 2d 3d 7d 30d 60d 180d 365d);
        my %added;

        foreach my $date (map { $today->plus_time_interval($_) } @daily_durations) {
            $date = $exchange->trade_date_after($date) unless ($exchange->trades_on($date));
            my $actual_day_string = $date->days_between($today) . 'd';
            next if ($added{$actual_day_string});    # We already saw this date in a previous iteration.
            $added{$actual_day_string} = 1;
            my $exchange_close_of_day = $exchange->closing_on($date);
            push @$trading_periods,
                +{
                date_start => {
                    date  => $start_of_day,
                    epoch => $today->epoch,
                },
                date_expiry => {
                    date  => $exchange_close_of_day->datetime,
                    epoch => $exchange_close_of_day->epoch,
                },
                duration => $actual_day_string,
                };
        }
        if ($now_hour > 0) {
            $now_hour = $now_minute < 45 ? $now_hour : $now_hour + 1;
            my $even_hour = $now_hour - ($now_hour % 2);
            push @$trading_periods,
                map { _get_combination_of_date_expiry_date_start({now => $now, date_start => $_, duration => \@even_hourly_durations}) }
                grep { $_->is_after($today) }
                map { $today->plus_time_interval($_ . 'h') } ($even_hour, $even_hour - 2);

            my $odd_hour = $now_hour % 2 ? $now_hour : $now_hour - 1;
            my @odd_hourly_durations = qw(3h 5h);
            push @$trading_periods,
                map { _get_combination_of_date_expiry_date_start({now => $now, date_start => $_, duration => \@odd_hourly_durations}) }
                grep { $_->is_after($today) }
                map { $today->plus_time_interval($_ . 'h') } ($odd_hour, $odd_hour - 2, $odd_hour - 4);

        }
        Cache::RedisDB->set($cache_keyspace, $trading_key, $trading_periods, 2700);
    }

    my @new_offerings;
    foreach my $o (@offerings) {
        # we do not want to offer intraday contract on other contracts
        my $minimum_contract_duration =
            $o->{contract_category} eq 'callput' ? Time::Duration::Concise->new({interval => $o->{min_contract_duration}})->seconds : 86400;
        foreach my $trading_period (@$trading_periods) {
            my $date_expiry      = $trading_period->{date_expiry}->{epoch};
            my $date_start       = $trading_period->{date_start}->{epoch};
            my $trading_duration = $date_expiry - $date_start;
            if ($trading_duration < $minimum_contract_duration) {
                next;
            } elsif ($now->day_of_week == 5
                and $trading_duration < 86400
                and ($date_expiry > $today_close or $date_start > $today_close))
            {
                next;
            } else {
                push @new_offerings, {%{$o}, trading_period => $trading_period};
            }
        }
    }

    return @new_offerings;
}

=head2 _get_combination_of_date_expiry_date_start

To get the date_start and date_expiry for a give trading duration

=cut

sub _get_combination_of_date_expiry_date_start {
    my $args       = shift;
    my $date_start = $args->{date_start};
    my @duration   = @{$args->{duration}};
    my $now        = $args->{now};
    my $early_date_start = $date_start->minus_time_interval('15m');
    my $start_date = {
        date  => $early_date_start->datetime,
        epoch => $early_date_start->epoch
    };

    return (
        map {
            +{
                date_start  => $start_date,
                date_expiry => {
                    date  => $_->datetime,
                    epoch => $_->epoch,
                },
                duration => ($_->hour - $date_start->hour) . 'h',
                }
            }
            grep {
            $now->is_before($_)
            } map {
            $date_start->plus_time_interval($_)
            } @duration
    );
}

=head2 _set_predefined_barriers

To set the predefined barriers on each trading period.
We do a binary search to find out the boundaries barriers associated with theo_prob [0.05,0.95] of a digital call,
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
    my $available_barriers = Cache::RedisDB->get($cache_keyspace, $barrier_key);
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
        } qw(0.05 0.95);

        @$available_barriers = _split_boundaries_barriers({
            pip_size           => $underlying->pip_size,
            start_tick         => $start_tick->quote,
            boundaries_barrier => \@boundaries_barrier
        });

        # Expires at the end of the available period.
        Cache::RedisDB->set($cache_keyspace, $barrier_key, $available_barriers, $date_expiry - $now->epoch);
    }
    if ($contract->{barriers} == 1) {
        $contract->{available_barriers} = $available_barriers;
        $contract->{barrier} = reduce { abs($current_tick->quote - $a) < abs($current_tick->quote - $b) ? $a : $b } @{$available_barriers};
    } elsif ($contract->{barriers} == 2) {
        my @lower_barriers  = grep { $current_tick_quote > $_ } @{$available_barriers};
        my @higher_barriers = grep { $current_tick_quote < $_ } @{$available_barriers};
        $contract->{available_barriers} = [\@lower_barriers, \@higher_barriers];
        $contract->{high_barrier}       = $higher_barriers[0];
        $contract->{low_barrier}        = $lower_barriers[0];
    }

    return;
}

=head2 _split_boundaries_barriers


-Split the boundaries barriers into 20 barriers.
The barriers will be split in the way more cluster towards current spot and gradually spread out from current spot.
- Included entry spot as well

=cut

sub _split_boundaries_barriers {
    my $args = shift;

    my $pip_size                    = $args->{pip_size};
    my $spot_at_start               = $args->{start_tick};
    my @boundaries_barrier          = @{$args->{boundaries_barrier}};
    my $distance_between_boundaries = abs($boundaries_barrier[0] - $boundaries_barrier[1]);
    my @steps                       = (1, 2, 3, 4, 5, 7, 9, 14, 24, 44);
    my $minimum_step                = roundnear($pip_size, $distance_between_boundaries / ($steps[-1] * 2));
    my @barriers = map { ($spot_at_start - $_ * $minimum_step, $spot_at_start + $_ * $minimum_step) } @steps;
    push @barriers, $spot_at_start;
    return @barriers;
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
