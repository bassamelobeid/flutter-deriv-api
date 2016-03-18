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
                landing_company   => 'japan',
                underlying_symbol => $symbol,
                start_type        => 'spot',
                expiry_type       => ['daily', 'intraday'],
                barrier_category  => ['euro_non_atm', 'american']});
        @offerings = _predefined_trading_period({
            offerings => \@offerings,
            exchange  => $exchange,
            symbol    => $symbol,
            date      => $now,
        });

        for my $o (@offerings) {
            my $cc = $o->{contract_category};

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
        available    => \@offerings,
        hit_count    => scalar(@offerings),
        open         => $open,
        close        => $close,
        feed_license => $underlying->feed_license
    };
}

=head2 _predefined_trading_period

We set the predefined trading periods based on Japan requirement:
Intraday contract:
1) Start at 15 min before closest even hour and expires with duration of 2 hours and 15 min.
   Mon-Friday
   00:00-02:00, 01:45-04:00, 03:45-06:00, 05:45-08:00, 0745-10:00,09:45-12:00, 11:45-14:00, 13:45-16:00, 15:45-18:00 <break>23:45-02:00, 01:45-04:00, 

   For AUDJPY,USDJPY,AUDUSD, it will be 
    00:00-02:00,01:45-04:00, 03:45-06:00, 05:45-08:00, 0745-10:00,09:45-12:00, 11:45-14:00, 13:45-16:00, 15:45-18:00<break> 21:45:00, 23:45-02:00,01:45-04:00, 03:45-06:00


3) Start at 00:45 and expires with durarion of 5 hours and 15 min and spaces the next available trading window by 4 hours.
   Example: 00:45-06:00 ; 04:45-10:00 ; 08:45-14:00 ; 12:45-18:00


Daily contract:
1) Daily contract: Start at 00:00GMT and end at 23:59:59GMT of the day
2) Weekly contract: Start at 00:00GMT first trading day of the week and end at the close of last trading day of the week
3) Monthly contract: Start at 00:00GMT of the first trading day of the calendar month and end at the close of the last trading day of the month
4) Quarterly contract: Start at 00:00GMT of the first trading day of the quarter and end at the close of the last trading day of the quarter.
6) Yearly contract: Start at 00:00GMT of the first trading day of the year and end at the close the last trading day of the year.

=cut

my $cache_keyspace = 'FINDER_PREDEFINED_SET';
my $cache_sep      = '==';

sub _predefined_trading_period {
    my $args              = shift;
    my @offerings         = @{$args->{offerings}};
    my $exchange          = $args->{exchange};
    my $now               = $args->{date};
    my $symbol            = $args->{symbol};
    my $now_hour          = $now->hour;
    my $now_minute        = $now->minute;
    my $now_date          = $now->date;
    my $trading_key       = join($cache_sep, $symbol, $now_date, $now_hour);
    my $today_close       = $exchange->closing_on($now);
    my $today_close_epoch = $today_close->epoch;
    my $today             = $now->truncate_to_day;                                # Start of the day object.
    my $trading_periods   = Cache::RedisDB->get($cache_keyspace, $trading_key);

    if (not $trading_periods) {
        $now_hour = $now_minute < 45 ? $now_hour : $now_hour + 1;
        my $even_hour = $now_hour - ($now_hour % 2);
        # We did not offer intraday contract after NY16. However, we turn on these three pairs on Japan
        my @skip_even_hour = (grep { $_ eq $symbol } qw(frxUSDJPY frxAUDJPY frxAUDUSD)) ? (18, 20) : (18, 20, 22);

        if (not grep { $even_hour == $_ } @skip_even_hour) {
            $trading_periods = [
                _get_intraday_trading_window({
                        now        => $now,
                        date_start => $today->plus_time_interval($even_hour . 'h'),
                        duration   => '2h'
                    })];
            if ($now_hour > 0) {
                my $odd_hour = ($now_hour % 2) ? $now_hour : $now_hour - 1;
                $odd_hour = $odd_hour % 4 == 1 ? $odd_hour : $odd_hour - 2;
                push @$trading_periods, map { _get_intraday_trading_window({now => $now, date_start => $_, duration => '5h'}) }
                    grep { $_->is_after($today) }
                    map { $today->plus_time_interval($_ . 'h') } ($odd_hour, $odd_hour - 4);
            }
        }
        # This is for 0 day contract
        push @$trading_periods,
            {
            date_start => {
                date  => $today->datetime,
                epoch => $today->epoch
            },
            date_expiry => {
                date  => $today_close->datetime,
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
        # we offer 0day contract on call/put
        my $minimum_contract_duration =
            (
                   $o->{contract_category} eq 'callput'
                or $o->{contract_category} eq 'endsinout'
            )
            ? $o->{expiry_type} eq 'intraday'
                ? Time::Duration::Concise->new({interval => $o->{min_contract_duration}})->seconds
                : ($today_close_epoch - $today->epoch)
            : 86400;

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
    my $early_date_start = ($now->day_of_week == 1 and $date_start->hour == 0) ? $date_start : $date_start->minus_time_interval('15m');
    my $date_expiry      = $date_start->plus_time_interval($duration);
    if ($now->is_before($date_expiry)) {
        return {
            date_start => {
                date  => $early_date_start->datetime,
                epoch => $early_date_start->epoch
            },
            date_expiry => {
                date  => $date_expiry->datetime,
                epoch => $date_expiry->epoch,
            },
            duration => $duration . '15m',
        };
    }
}

=head2 _get_trade_date_of_daily_window

To get the trade date of supplied start and end of the window

=cut

sub _get_trade_date_of_daily_window {
    my $args                    = shift;
    my $start_of_current_window = $args->{current_date_start};
    my $start_of_next_window    = $args->{next_date_start};
    my $duration                = $args->{duration};
    my $exchange                = $args->{exchange};
    my $date_start =
        $exchange->trades_on($start_of_current_window) ? $start_of_current_window : $exchange->trade_date_after($start_of_current_window);
    my $date_expiry = $exchange->closing_on($exchange->trade_date_before($start_of_next_window));

    return {
        date_start => {
            date  => $date_start->datetime,
            epoch => $date_start->epoch
        },
        date_expiry => {
            date  => $date_expiry->datetime,
            epoch => $date_expiry->epoch,
        },
        duration => $duration,
    };
}

=head2 _get_daily_trading_window

To get the weekly, monthly , quarterly, and yearly trading window 

=cut

sub _get_daily_trading_window {
    my $args     = shift;
    my $duration = $args->{duration};
    my $now      = $args->{now};
    my $exchange = $args->{exchange};
    my $now_dow  = $now->day_of_week;
    my $now_year = $now->year;
    my @daily_duration;

    # weekly contract
    my $first_day_of_week      = $now->truncate_to_day->minus_time_interval($now_dow - 1 . 'd');
    my $first_day_of_next_week = $first_day_of_week->plus_time_interval('7d');
    push @daily_duration,
        _get_trade_date_of_daily_window({
            current_date_start => $first_day_of_week,
            next_date_start    => $first_day_of_next_week,
            duration           => '1W',
            exchange           => $exchange
        });

    # monthly contract
    my $first_day_of_month      = Date::Utility->new('1-' . $now->month_as_string . '-' . $now_year);
    my $first_day_of_next_month = Date::Utility->new('1-' . $now->months_ahead(1));
    push @daily_duration,
        _get_trade_date_of_daily_window({
            current_date_start => $first_day_of_month,
            next_date_start    => $first_day_of_next_month,
            duration           => '1M',
            exchange           => $exchange
        });

    # quarterly contract
    my $current_quarter_month     = $now->quarter_of_year * 3 - 2;
    my $first_day_of_quarter      = Date::Utility->new($now_year . "-$current_quarter_month-01");
    my $first_day_of_next_quarter = Date::Utility->new('1-' . $first_day_of_quarter->months_ahead(3));
    push @daily_duration,
        _get_trade_date_of_daily_window({
            current_date_start => $first_day_of_quarter,
            next_date_start    => $first_day_of_next_quarter,
            duration           => '3M',
            exchange           => $exchange
        });

    # yearly contract
    my $first_day_of_year = Date::Utility->new('01-Jan-' . $now_year);
    my $first_day_of_next_year = Date::Utility->new('01-Jan-' . ($now_year + 1));
    push @daily_duration,
        _get_trade_date_of_daily_window({
            current_date_start => $first_day_of_year,
            next_date_start    => $first_day_of_next_year,
            duration           => '1Y',
            exchange           => $exchange
        });

    return @daily_duration;

}

=head2 _set_predefined_iarriers

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
        $available_barriers = _split_boundaries_barriers({
            pip_size           => $underlying->pip_size,
            start_tick         => $start_tick->quote,
            boundaries_barrier => \@boundaries_barrier
        });

        # Expires at the end of the available period.
        Cache::RedisDB->set($cache_keyspace, $barrier_key, $available_barriers, $date_expiry - $now->epoch);
    }

    my $expired_barriers = _get_expired_barriers({
        available_barriers => $available_barriers,
        start              => $date_start,
        expiry             => $date_expiry,
        now                => $now->epoch,
        underlying         => $underlying
    });

    if ($contract->{barriers} == 1) {
        my @barriers = sort values %$available_barriers;

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
    my $expired_barriers     = Cache::RedisDB->get($cache_keyspace, $expired_barriers_key);
    my ($high, $low) = @{
        $underlying->get_high_low_for_period({
                start => $date_start,
                end   => $now,
            })}{'high', 'low'};
if (not $high){
print "start time is [$date_start] now [$now] no high[$high]\n";}
    my @barriers                  = sort values %$available_barriers;
    my %skip_list                 = map { $_ => 1 } (@$expired_barriers);
    my @unexpired_barriers        = grep { !$skip_list{$_} } @barriers;
    my $new_added_expired_barrier = 0;
    foreach my $barrier (@unexpired_barriers) {
        if ($barrier < $high && $barrier > $low) {
            push @$expired_barriers, $barrier;
            $new_added_expired_barrier++;
        }
    }
    if ($new_added_expired_barrier > 0) {
        Cache::RedisDB->set($cache_keyspace, $expired_barriers_key, $expired_barriers, $date_expiry - $now);
    }

    return $expired_barriers;

}

=head2 _get_barriers_pair

- For staysinout contract, we need to pair the barriers symmetry, ie ( 45, 55), (40,60), (35,65), (20,80), (5,95) 
- For endsinout contract, we need to pair barriers as follow: (45,55), (40,50), (50,60), (35,45), (55,65), (20,40), (60,80)

Note: 45 is -5d from the spot at start and 55 is +5d from spot at start
where d is the minimum increment that determine by divided the distance of boundaries by 90 (45 each side) 


=cut

sub _get_barriers_pair {
    my $args = shift;

    my $contract_category        = $args->{contract_category};
    my $available_barriers       = $args->{available_barriers};
    my $list_of_expired_barriers = $args->{expired_barriers};
    my @barrier_pairs =
        $contract_category eq 'staysinout'
        ? ([45, 55], [40, 60], [35, 65], [20, 80], [5, 95])
        : ([45, 55], [40, 50], [50, 60], [35, 45], [55, 65], [20, 40], [60, 80]);
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

-Split the boundaries barriers into 10 barriers by divided the distance of boundaries by 90 (45 each side) - to be used as increment.
The barriers will be split in the way more cluster towards current spot and gradually spread out from current spot.
- Included entry spot as well

=cut

sub _split_boundaries_barriers {
    my $args = shift;

    my $pip_size                    = $args->{pip_size};
    my $spot_at_start               = $args->{start_tick};
    my @boundaries_barrier          = @{$args->{boundaries_barrier}};
    my $distance_between_boundaries = abs($boundaries_barrier[0] - $boundaries_barrier[1]);
    my @steps                       = (5, 10, 15, 30, 45);
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
