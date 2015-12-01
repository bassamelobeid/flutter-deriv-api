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
    my ($open, $close, @offerings);
    if ($exchange->trades_on($now)) {
        $open  = $exchange->opening_on($now)->epoch;
        $close = $exchange->closing_on($now)->epoch;
        my $flyby = BOM::Product::Offerings::get_offerings_flyby;
        @offerings = $flyby->query({
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
Intraday contract:
1) Start at 15 min before closest even hour and expires with duration of 2 hours and 15 min.
   Mon-Friday:
   00:00-02:00, 01:45-04:00, 03:45-06:00, 05:45-08:00, 0745-10:00,09:45-12:00, 11:45-14:00, 13:45-16:00, 15:45-18:00<break> 23:45-02:00, 01:45-04:00
   For those JPY pairs, it will be 
   00:00-02:00,01:45-04:00, 03:45-06:00, 05:45-08:00, 0745-10:00,09:45-12:00, 11:45-14:00, 13:45-16:00, 15:45-18:00<break> 21:45:00, 23:45-02:00,01:45-04:00, 03:45-06:00

3) Start at 00:45 and expires with durarion of 5 hours and 15 min and spaces the next available trading window by 4 hours.
   00:45-06:00 ; 04:45-10:00 ; 08:45-14:00 ; 12:45-18:00

Daily contract:
1) Daily contract: Start at 00:00GMT and end at 23:59:59GMT of the day
2) Weekly contract: Start at 00:00GMT first trading day of the week and end at the close of last trading day of the week
3) Monthly contract: Start at 00:00GMT of the first trading day of the calendar month and end at the close of the last trading day of the month
4) Quarterly contract: Start at 00:00GMT of the first trading day of the quarter and end at the close of the last trading day of the quarter.
6) Yearly contract: Start at 00:00GMT of the first trading day of the year and end at the close the last trading day of the year.

=cut

my $cache_keyspace = 'FINDER_PREDEFINED_TRADING';
my $cache_sep      = '==';

sub _predefined_trading_period {
    my $args                 = shift;
    my @offerings            = @{$args->{offerings}};
    my $exchange             = $args->{exchange};
    my $now                  = $args->{date};
    my $now_hour             = $now->hour;
    my $now_minute           = $now->minute;
    my $now_date             = $now->date;
    my $trading_key          = join($cache_sep, $exchange->symbol, $now_date, $now_hour);
    my $today_close          = $exchange->closing_on($now);
    my $today_close_datetime = $today_close->datetime;
    my $today_close_epoch    = $today_close->epoch;
    my $today                = $now->truncate_to_day;                                       # Start of the day object.
    my $trading_periods      = Cache::RedisDB->get($cache_keyspace, $trading_key);
    if (not $trading_periods) {
        $now_hour = $now_minute < 45 ? $now_hour : $now_hour + 1;
        my $even_hour = $now_hour - ($now_hour % 2);
        $trading_periods = [
            _get_intraday_trading_window({
                    now        => $now,
                    date_start => $today->plus_time_interval($even_hour . 'h'),
                    duration   => '2h15m'
                })];
        if ($now_hour > 0) {
            my $odd_hour = ($now_hour % 2) ? $now_hour : $now_hour - 1;
            $odd_hour = $odd_hour % 4 == 1 ? $odd_hour : $odd_hour - 2;
            push @$trading_periods, map { _get_intraday_trading_window({now => $now, date_start => $_, duration => '5h15m'}) }
                grep { $_->is_after($today) }
                map { $today->plus_time_interval($_ . 'h') } ($odd_hour, $odd_hour - 4);
        }
        # This is for 0 day contract
        push @$trading_periods,
            {
            date_start => {
                date  => $today->datetime,
                epoch => $today->epoch
            },
            date_expiry => {
                date  => $today_close_datetime,
                epoch => $today_close_epoch
            },
            duration => '0d'
            };

        push @$trading_periods,
            _get_daily_trading_window({
                now      => $now,
                duration => $_,
                exchange => $exchange
            });

        my $key_expiry = $now_minute < 45 ? $now_date . ' ' . $now_hour . ':45:00' : $now_date . ' ' . $now_hour . ':00:00';
        Cache::RedisDB->set($cache_keyspace, $trading_key, $trading_periods, Date::Utility->new($key_expiry)->epoch - $now->epoch);

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
                and ($date_expiry > $today_close_epoch or $date_start > $today_close_epoch))
            {
                next;
            } else {
                push @new_offerings, {%{$o}, trading_period => $trading_period};
            }
        }
    }

    return @new_offerings;
}

=head2 _get_intraday_trading_window

To get the intraday trading window of a trading duration. Start at 15 minute before the date_start

=cut

sub _get_intraday_trading_window {
    my $args             = shift;
    my $date_start       = $args->{date_start};
    my $duration         = $args->{duration};
    my $now              = $args->{now};
    my $early_date_start = $date_start->minus_time_interval('15m');
    my $date_expiry      = $date_start->plus_time_interval($duration);

    if ($now->is_before($date_expiry) and $date_expiry->hour < 18 or ($now->day_of_week ==1 and $early_date_start->hour != 23)) {
        return {
            date_start => {
                date  => $early_date_start->datetime,
                epoch => $early_date_start->epoch
            },
            date_expiry => {
                date  => $date_expiry->datetime,
                epoch => $date_expiry->epoch,
            },
            duration => $duration,
        };
    }
}

=head2 _get_daily_trading_window

To get the weekly, monthly , quarterly, and yearly trading window 

=cut

sub _get_daily_trading_window {
    my $args     = shift;
    my $duration = $args->{duration};
    my $now      = $args->{now};
    my $now_dow  = $now->day_of_week;
    my $now_year = $now->year;
    my @daily_duration;

    # weekly contract
    my $first_day_of_week = $now->truncate_to_day->minus_time_interval($now_dow - 1 . 'd');
    my $last_day_of_week  = $now->truncate_to_day->plus_time_interval(5 - $now_dow . 'd');

    my $weekly_date_start  = $exchange->trades_on($first_day_of_week) ? $first_day_of_week : $exchange->trade_date_after($first_day_of_week);
    my $weekly_date_expiry = $exchange->trades_on($last_day_of_week)  ? $last_day_of_week  : $exchange->trade_date_before($last_day_of_week);

    push @daily_duration,
        {
        date_start => {
            date  => $weekly_date_start->datetime,
            epoch => $weekly_date_start->epoch
        },
        date_expiry => {
            date  => $weekly_date_expiry->datetime,
            epoch => $weekly_date_expiry->epoch,
        },
        duration => '1W',
        };

    # monthly contract
    my $first_day_of_month    = Date::Utility->new('1-' . $now->month_as_string . '-' . $now_year);
    my $first_day_of_next_mth = Date::Utility->new('1-' . $now->months_ahead(1));
    my $monthly_date_start    = $exchange->trades_on($first_day_of_month) ? $first_day_of_month : $exchange->trade_date_after($first_day_of_month);
    my $monthly_date_expiry   = $exchange->trade_date_before($first_day_of_next_mth);

    push @daily_duration,
        {
        date_start => {
            date  => $monthly_date_start->datetime,
            epoch => $monthly_date_start->epoch
        },
        date_expiry => {
            date  => $monthly_date_expiry->datetime,
            epoch => $monthly_date_expiry->epoch,
        },
        duration => '1M',
        };

    # quarterly contract
    my $current_quarter_month = $now->quarter * 3 - 2;
    my $first_day_of_quarter  = Date::Utility->new($now_year . "-$current_quarter_month-01");
    my $first_day_of_next_quarter = Date::Utility->new('1-' . $first_day_of_quarter->months_ahead(3));
    my $quarterly_date_start =
        $exchange->trades_on($first_day_of_quarter) ? $first_day_of_quarter : $exchange->trade_date_after($first_day_of_quarter);
    my $quarterly_date_expiry     = $exchange->trade_date_before($first_day_of_next_quarter);

    push @daily_duration,
        {
        date_start => {
            date  => $quarterly_date_start->datetime,
            epoch => $quarterly_date_start->epoch
        },
        date_expiry => {
            date  => $quarterly_date_expiry->datetime,
            epoch => $quarterly_date_expiry->epoch,
        },
        duration => '3M',
        };

    # yearly contract
    my $first_day_of_year  = Date::Utility->new('01-Jan-' . $now_year);
    my $last_day_of_year   = Date::Utility->new('31-Dec' . $now_year);
    my $yearly_date_start  = $exchange->trades_on($first_day_of_year) ? $first_day_of_year : $exchange->trade_date_after($first_day_of_year);
    my $yearly_date_expiry = $exchange->trades_on($last_day_of_year) ? $last_day_of_year : $exchange->trade_date_before($last_day_of_year);

    push @daily_duration,
        {
        date_start => {
            date  => $yearly_date_start->datetime,
            epoch => $yearly_date_start->epoch
        },
        date_expiry => {
            date  => $yearly_date_expiry->datetime,
            epoch => $yearly_date_expiry->epoch,
        },
        duration => '1Y',
        };

    return @daily_duration;

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
    my @barriers                    = map { ($spot_at_start - $_ * $minimum_step, $spot_at_start + $_ * $minimum_step) } @steps;
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
