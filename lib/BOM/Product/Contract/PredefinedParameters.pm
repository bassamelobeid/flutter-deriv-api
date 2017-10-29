package BOM::Product::Contract::PredefinedParameters;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(get_predefined_offerings get_trading_periods generate_trading_periods update_predefined_highlow next_generation_epoch);

use JSON qw(to_json from_json);
use Time::HiRes;
use Date::Utility;
use List::Util qw(first min max);
use Math::CDF qw(qnorm);
use Format::Util::Numbers qw/roundcommon/;

use Quant::Framework;
use Finance::Contract::Category;
use LandingCompany::Offerings qw(get_offerings_flyby);

use BOM::MarketData qw(create_underlying);
use BOM::Platform::RedisReplicated;
use BOM::Platform::Runtime;
use BOM::Platform::Chronicle;

my %supported_contract_types = (
    CALLE        => 1,
    PUT          => 1,
    EXPIRYMISS   => 1,
    EXPIRYRANGEE => 1,
    RANGE        => 1,
    UPORDOWN     => 1,
    ONETOUCH     => 1,
    NOTOUCH      => 1,
);

my $cache_namespace = 'predefined_parameters';

sub _trading_calendar {
    my $for_date = shift;

    return Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader($for_date), $for_date);
}

=head2 get_predefined_offerings

Returns an array reference of predefined product offerings for an underlying symbol.
Each offering has the following additional keys:
 - available_barriers
 - expired_barriers
 - trading_period

->get_predefined_offerings({symbol => 'frxUSDJPY'}); # get latest predefined offerings
->get_predefined_offerings({symbol => 'frxUSDJPY', date => $date}); # historical predefined offerings
->get_predefined_offerings({symbol => 'frxUSDJPY', date => $date, landing_company => 'costarica'}); # specific landing_company

=cut

sub get_predefined_offerings {
    my $args = shift;

    my ($symbol, $date, $landing_company) = @{$args}{'symbol', 'date', 'landing_company'};
    my @offerings = _get_offerings($symbol, $landing_company);
    my $underlying = create_underlying($symbol, $date);
    $date //= Date::Utility->new;

    my $new = _apply_predefined_parameters($date, $underlying, \@offerings);

    return $new if $new and @$new;
    return [];
}

=head2 get_trading_periods

Returns an array reference of trading period for an underlying symbol from redis cache.
Returns an empty array reference if request period is not found in cache.

Each trading period a hash reference with  the following keys:
 - date_start
 - date_expiry
 - duration

->get_trading_periods('frxUSDJPY'); # get latest trading period
->get_trading_periods('frxUSDJPY', $date); # historical trading period

=cut

sub get_trading_periods {
    my ($symbol, $date) = @_;

    my $underlying = create_underlying($symbol, $date);
    $date //= Date::Utility->new;

    my $for_date = $underlying->for_date;
    my $method   = $for_date ? 'get_for' : 'get';
    my $key      = join '_', ('trading_period', $underlying->symbol, $date->date, $date->hour);
    my $cache    = BOM::Platform::Chronicle::get_chronicle_reader($for_date)->$method($cache_namespace, $key, $for_date);

    return $cache // [];
}

=head2 generate_trading_periods

Generates and returns an array reference of trading period for an underlying symbol.

Each trading period a hash reference with  the following keys:
 - date_start
 - date_expiry
 - duration

->generate_trading_periods('frxUSDJPY'); # generates latest trading period
->generate_trading_periods('frxUSDJPY', $date); # generates trading period based on historical conditions

Generation algorithm are based on the Japan regulators requirements:
Intraday contract:
1) Start at 15 min before closest even hour and expires with duration of 2 hours and 15 min.
   Mon-Friday
   00:00-02:00, 01:45-04:00, 03:45-06:00, 05:45-08:00, 0745-10:00,09:45-12:00, 11:45-14:00, 13:45-16:00, 15:45-18:00 <break>23:45-02:00, 01:45-04:00,

   For AUDJPY,USDJPY,AUDUSD, it will be:
    00:00-02:00,01:45-04:00, 03:45-06:00, 05:45-08:00, 0745-10:00,09:45-12:00, 11:45-14:00, 13:45-16:00, 15:45-18:00 <break> 21:45:00-23:59:59, 23:45-02:00,01:45-04:00, 03:45-06:00


2) Start at 00:45 and expires with durarion of 5 hours and 15 min and spaces the next available trading window by 4 hours.
   Example: 00:45-06:00 ; 04:45-10:00 ; 08:45-14:00 ; 12:45-18:00


Daily contract:
1) Daily contract: Start at 00:00GMT and end at 23:59:59GMT of the day
2) Weekly contract: Start at 00:00GMT first trading day of the week and end at the close of last trading day of the week
3) Monthly contract: Start at 00:00GMT of the first trading day of the calendar month and end at the close of the last trading day of the month
4) Quarterly contract: Start at 00:00GMT of the first trading day of the quarter and end at the close of the last trading day of the quarter.
5) Yearly contract: Start at 00:00GMT of the first trading day of the year and end at the close of the last trading day of the year.

=cut

sub generate_trading_periods {
    my ($symbol, $date) = @_;

    my $underlying = create_underlying($symbol, $date);
    my $trading_calendar = _trading_calendar($date);
    $date //= Date::Utility->new;

    return [] unless $trading_calendar->trades_on($underlying->exchange, $date);

    my @trading_periods = _get_daily_trading_window($underlying, $date);
    my @intraday_periods = _get_intraday_trading_window($underlying, $date);
    push @trading_periods, @intraday_periods if @intraday_periods;

    return \@trading_periods;
}

sub trading_period_key {
    my ($underlying_symbol, $date) = @_;

    my $key = join '_', ('trading_period', $underlying_symbol, $date->date, $date->hour);
    return ($cache_namespace, $key);
}

=head2 update_predefined_highlow

For a given tick, it updates a list of relevant high-low period.

=cut

sub update_predefined_highlow {
    my $tick_data = shift;

    my $underlying = create_underlying($tick_data->{symbol});
    my $now        = $tick_data->{epoch};
    my @periods    = @{get_trading_periods($underlying->symbol)};
    my $new_quote  = $tick_data->{quote};

    return unless @periods;

    foreach my $period (@periods) {
        my $key = join '_', ('highlow', $underlying->symbol, $period->{date_start}->{epoch}, $period->{date_expiry}->{epoch});
        my $cache = BOM::Platform::RedisReplicated::redis_read()->get($cache_namespace . '::' . $key);
        my ($new_high, $new_low);

        if ($cache) {
            my $current_highlow = from_json($cache);
            my ($high, $low) = map { $current_highlow->[$_] } (0, 1);
            $new_high = max($new_quote, $high);
            $new_low = min($new_quote, $low);
        } else {
            my $db_highlow = $underlying->get_high_low_for_period({
                start => $period->{date_start}->{epoch},
                end   => $now,
            });
            $new_high = defined $db_highlow->{high} ? max($new_quote, $db_highlow->{high}) : $new_quote;
            $new_low = defined $db_highlow->{low} ? min($new_quote, $db_highlow->{low}) : $new_quote;
        }
        my $ttl = max(1, $period->{date_expiry}->{epoch} - $now);
        # not using chronicle here because we don't want to save historical highlow data
        BOM::Platform::RedisReplicated::redis_write()->set($cache_namespace . '::' . $key, to_json([$new_high, $new_low]), 'EX', $ttl);
    }

    return 1;
}

sub _get_predefined_highlow {
    my ($underlying, $period) = @_;

    if ($underlying->for_date) {
        # for historical access, we fetch ohlc directly from the database
        return @{
            $underlying->get_high_low_for_period({
                    start => $period->{date_start}->{epoch},
                    end   => $period->{date_expiry}->{epoch},
                })}{'high', 'low'};
    }

    my $highlow_key = join '_', ('highlow', $underlying->symbol, $period->{date_start}->{epoch}, $period->{date_expiry}->{epoch});
    my $cache = BOM::Platform::RedisReplicated::redis_read->get($cache_namespace . '::' . $highlow_key);

    return @{from_json($cache)} if ($cache);
    return ();
}

=head2 next_generation_interval

Returns XX:45 if requested date is before XX:45, else returns XX:00

=cut

sub next_generation_epoch {
    my $from_date = shift;

    my $minute = $from_date->minute;

    my $next_gen_epoch =
        ($minute < 45)
        ? Date::Utility->new->today->plus_time_interval($from_date->hour . 'h45m')->epoch
        : Date::Utility->new->today->plus_time_interval($from_date->hour + 1 . 'h')->epoch;

    return $next_gen_epoch;
}

sub _flyby {
    my $landing_company = shift;

    $landing_company //= 'costarica';
    return get_offerings_flyby(BOM::Platform::Runtime->instance->get_offerings_config, $landing_company);
}

sub supported_symbols {
    return _flyby()->query({submarket => 'major_pairs'}, ['underlying_symbol']);
}

# we perform three things here:
# - split offerings into applicable trading periods.
# - calculate barriers.
# - set expired barriers.
sub _apply_predefined_parameters {
    my ($date, $underlying, $offerings) = @_;

    my $trading_periods = get_trading_periods($underlying->symbol, $underlying->for_date);
    my $trading_calendar = _trading_calendar($underlying->for_date);

    return () unless @$trading_periods;

    my $close_epoch = $trading_calendar->closing_on($underlying->exchange, $date)->epoch;
    # full trading seconds
    my $trading_seconds = $close_epoch - $date->truncate_to_day->epoch;

    my @new_offerings;
    foreach my $offering (@$offerings) {
        # we offer 0 day (end of day) and intraday durations to callput only
        my $minimum_contract_duration;
        if ($offering->{contract_category} ne 'callput') {
            $minimum_contract_duration = 86400;
        } else {
            $minimum_contract_duration =
                $offering->{expiry_type} eq 'intraday'
                ? Time::Duration::Concise->new({interval => $offering->{min_contract_duration}})->seconds
                : $trading_seconds;
        }

        my $maximum_contract_duration =
            ($offering->{contract_category} eq 'callput' and $offering->{expiry_type} eq 'intraday')
            ? 21600
            : Time::Duration::Concise->new({interval => $offering->{max_contract_duration}})->seconds;

        foreach my $trading_period (grep { defined } @$trading_periods) {
            my $date_expiry      = $trading_period->{date_expiry}->{epoch};
            my $date_start       = $trading_period->{date_start}->{epoch};
            my $trading_duration = $date_expiry - $date_start;
            if ($trading_duration < $minimum_contract_duration or $trading_duration > $maximum_contract_duration) {
                next;
            } elsif ($date->day_of_week == 5
                and $trading_duration < 86400
                and ($date_expiry > $close_epoch or $date_start > $close_epoch))
            {
                next;
            } else {
                my $available_barriers = _calculate_available_barriers($underlying, $offering, $trading_period);
                my $expired_barriers =
                    ($offering->{barrier_category} eq 'american') ? _get_expired_barriers($underlying, $available_barriers, $trading_period) : [];

                push @new_offerings,
                    +{
                    %{$offering},
                    trading_period     => $trading_period,
                    available_barriers => $available_barriers,
                    expired_barriers   => $expired_barriers,
                    };
            }
        }
    }

    return \@new_offerings;
}

sub _get_expired_barriers {
    my ($underlying, $available_barriers, $trading_period) = @_;

    my ($high, $low) = _get_predefined_highlow($underlying, $trading_period);

    unless ($high and $low) {
        warn "highlow is undefined for " . $underlying->symbol . " [$trading_period->{date_start}->{date} - $trading_period->{date_expiry}->{date}]";
        return [];
    }

    my @expired_barriers;
    foreach my $barrier (@$available_barriers) {
        my $ref_barrier = (ref $barrier ne 'ARRAY') ? [$barrier] : $barrier;
        my @expired = grep { $_ <= $high && $_ >= $low } @$ref_barrier;
        push @expired_barriers, $barrier if @expired;
    }

    return \@expired_barriers;
}

#To set the predefined barriers on each trading period.
#We do a binary search to find out the boundaries barriers associated with theo_prob [0.05,0.95] of a digital call,
#then split into 20 barriers that within this boundaries. The barriers will be split in the way more cluster towards current spot and gradually spread out from current spot.
sub _calculate_available_barriers {
    my ($underlying, $offering, $trading_period) = @_;

    my $barriers = _calculate_barriers({
        underlying      => $underlying,
        trading_periods => $trading_period,
    });

    my $available_barriers;
    if ($offering->{barriers} == 1) {
        delete $barriers->{50} if $offering->{barrier_category} eq 'american';
        $available_barriers = [map { $underlying->pipsized_value($_) } sort { $a <=> $b } values %$barriers];
    } elsif ($offering->{barriers} == 2) {
        # For staysinout contract, we need to pair the barriers symmetry, ie (25,75), (15,85), (5,95)
        # For endsinout contract, we need to pair barriers as follow: (75,95), (62,85),(50,75),(38,62),(25,50),(15,38),(5,25)
        # Note: 42 is -8d from the spot at start and 58 is +8d from spot at start
        # where d is the minimum increment that determine by divided the distance of boundaries by 95 (45 each side)
        my @barrier_pairs =
            $offering->{contract_category} eq 'staysinout'
            ? ([25, 75], [15, 85], [5, 95])
            : ([75, 95], [62, 85], [50, 75], [38, 62], [25, 50], [15, 38], [5, 25]);

        $available_barriers =
            [map { [$underlying->pipsized_value($barriers->{$_->[0]}), $underlying->pipsized_value($barriers->{$_->[1]})] } @barrier_pairs];
    }

    return $available_barriers;
}

sub _get_spot {
    my ($underlying, $trading_period) = @_;
    my $spot;
    my $date_start = Date::Utility->new($trading_period->{date_start}->{epoch});
    # special handling at for barriers, which start at Monday at 00:00:00
    # caused by our tick storage misdesign: ticks are available only for
    # trading hours, meanwhile we have ticks from providers sinse Sunday 22:00.
    # So, ticks will be taken directly from feed-redis.
    my $realtime = (time - $trading_period->{date_start}->{epoch} < 2);
    my $take_from_distributor =
           $realtime
        && ($date_start->day_of_week == 1)
        && ($date_start->time_hhmmss eq '00:00:00');
    if ($take_from_distributor) {
        my $redis = BOM::Platform::RedisReplicated::redis_read();
        if (my $tick_json = $redis->get('Distributor::QUOTE::' . $underlying->symbol)) {
            $spot = decode_json($tick_json)->{quote};
        }
    }
    if ($take_from_distributor || !$spot) {
        my $tick = $underlying->tick_at($trading_period->{date_start}->{epoch}, {allow_inconsistent => 1});
        unless ($tick) {
            # If spot at requested time is not present, we will use current spot.
            # This should not happen in production, it is for QA purposes.
            warn
                "using current tick to calculate barrier for period [$trading_period->{date_start}->{date} - $trading_period->{date_expiry}->{date}]";
            $tick = $underlying->spot_tick;
        }
        $spot = $tick->quote if $tick;
    }
    if (!defined $spot) {
        die 'Could not retrieve tick for ' . $underlying->symbol . ' at ' . $date_start->datetime;
    }
    return $spot;
}

sub _calculate_barriers {
    my $args = shift;

    my ($underlying, $trading_period) = @{$args}{qw(underlying trading_periods)};
    my $key = join '_', ('barriers', $underlying->symbol, $trading_period->{date_start}->{epoch}, $trading_period->{date_expiry}->{epoch});
    my $cache = BOM::Platform::RedisReplicated::redis_read()->get($cache_namespace . '::' . $key);

    return from_json($cache) if $cache;

    my $tiy = ($trading_period->{date_expiry}->{epoch} - $trading_period->{date_start}->{epoch}) / (365 * 86400);

    my $spot_at_start = _get_spot($underlying, $trading_period);
    my @initial_barriers = map { _get_strike_from_call_bs_price($_, $tiy, $spot_at_start, 0.1) } (0.05, 0.95);

    # Split the boundaries barriers into 9 barriers by divided the distance of boundaries by 95 (45 each side) - to be used as increment.
    # The barriers will be split in the way more cluster towards current spot and gradually spread out from current spot.
    # Included entry spot as well
    my $distance_between_boundaries = abs($initial_barriers[0] - $initial_barriers[1]);
    my @steps                       = (12, 25, 35, 45);
    my $minimum_step                = roundcommon($underlying->pip_size, $distance_between_boundaries / ($steps[-1] * 2));
    my %barriers                    = map { (50 - $_ => $spot_at_start - $_ * $minimum_step, 50 + $_ => $spot_at_start + $_ * $minimum_step) } @steps;
    $barriers{50} = $spot_at_start;

    my $ttl = max(1, $trading_period->{date_expiry}->{epoch} - $trading_period->{date_start}->{epoch});
    BOM::Platform::RedisReplicated::redis_write()->set($cache_namespace . '::' . $key, to_json(\%barriers), 'EX', $ttl);

    return \%barriers;
}

=head2 _get_strike_from_call_bs_price

To get the strike that associated with a given call bs price.

=cut

sub _get_strike_from_call_bs_price {
    my ($call_price, $T, $spot, $vol) = @_;

    my $q  = 0;
    my $r  = 0;
    my $d2 = qnorm($call_price * exp($r * $T));
    my $d1 = $d2 + $vol * sqrt($T);

    my $strike = $spot / exp($d1 * $vol * sqrt($T) - ($r - $q + ($vol * $vol) / 2) * $T);
    return $strike;
}

# Japan's intraday predefined trading window are as follow:
# 2 hours and 15 min duration:
# For AUDJPY, USDJPY, AUDUSD
# 00:00-02:00,01:45-04:00, 03:45-06:00, 05:45-08:00, 0745-10:00,09:45-12:00, 11:45-14:00, 13:45-16:00, 15:45-18:00,21:45- 23:59:59, 23:45-02:00,01:45-04:00, 03:45-06:00
#
# For other pairs:
# 00:00-02:00,01:45-04:00, 03:45-06:00, 05:45-08:00, 0745-10:00,09:45-12:00, 11:45-14:00, 13:45-16:00, 15:45-18:00,23:45-02:00,01:45-04:00, 03:45-06:00
#
# 5 hours and 15 min duration:
# 00:45-06:00 ; 04:45-10:00 ; 08:45-14:00 ; 12:45-18:00
#
# Hence, we will generate the window at HH::45 (HH is the predefined trading hour) to include any new trading window and will also generate the trading window again at the next HH:00 to remove any expired trading window.

sub _get_intraday_trading_window {
    my ($underlying, $date) = @_;
    my @intraday_windows;

    my $start_of_day = $date->truncate_to_day;
    my ($current_hour, $minute) = ($date->hour, $date->minute);
    my $hour = $minute < 45 ? $current_hour : $current_hour + 1;
    my $even_hour = $hour - ($hour % 2);

    # We only want odd hour of 1, 5, 9, 13
    my $odd_hour = ($hour % 2) ? $hour : $hour - 1;
    $odd_hour = $odd_hour % 4 == 1 ? $odd_hour : $odd_hour - 2;

    # We did not offer intraday contract after NY16. However, we turn on these three pairs on Japan
    my @skips_hour = (first { $_ eq $underlying->symbol } qw(frxUSDJPY frxAUDJPY frxAUDUSD)) ? (18, 20) : (18, 20, 22);
    my $skips_intraday = first { $even_hour == $_ } @skips_hour;

    # At 17:45GMT, we should still have the one that expired on 18GMT
    if ($even_hour == 18 and $current_hour == 17) {
        push @intraday_windows,
            _get_intraday_window({
                now        => $date,
                date_start => $start_of_day->plus_time_interval(($even_hour - 2) . 'h'),
                duration   => '2h',
                underlying => $underlying,
            });

        push @intraday_windows,
            _get_intraday_window({
                now        => $date,
                underlying => $underlying,
                date_start => $start_of_day->plus_time_interval($odd_hour - 4 . 'h'),
                duration   => '5h'
            });

    }

    return @intraday_windows if $skips_intraday;

    my $window_2h = _get_intraday_window({
        now        => $date,
        underlying => $underlying,
        date_start => $start_of_day->plus_time_interval($even_hour . 'h'),
        duration   => '2h'
    });

    if ($window_2h) {
        # Previous 2 hours contract should be always available in the first 15 minutes of the next one
        # (except start of the trading day and also the first window after the break)
        my $skips_prev_window = first { $even_hour - 2 == $_ } @skips_hour;
        if (($date->epoch - $window_2h->{date_start}->{epoch}) / 60 < 15 && $even_hour - 2 >= 0 && !$skips_prev_window) {
            push @intraday_windows,
                _get_intraday_window({
                    now        => $date,
                    underlying => $underlying,
                    date_start => $start_of_day->plus_time_interval(($even_hour - 2) . 'h'),
                    duration   => '2h'
                });
        }

        push @intraday_windows, $window_2h;
    }
    if ($odd_hour >= 1 and $odd_hour < 17) {
        push @intraday_windows,
            _get_intraday_window({
                now        => $date,
                underlying => $underlying,
                date_start => $start_of_day->plus_time_interval($odd_hour . 'h'),
                duration   => '5h'
            });
    }

    my $previous_odd_hour = $odd_hour - 4;
    if ($previous_odd_hour >= 1 and $previous_odd_hour <= 13) {
        push @intraday_windows,
            _get_intraday_window({
                now        => $date,
                underlying => $underlying,
                date_start => $start_of_day->plus_time_interval($previous_odd_hour . 'h'),
                duration   => '5h'
            });
    }

    return @intraday_windows;
}

=head2 _get_daily_trading_window

To get the end of day, weekly, monthly , quarterly, and yearly trading window.

=cut

sub _get_daily_trading_window {
    my ($underlying, $date) = @_;

    my $trading_calendar = _trading_calendar($underlying->for_date);
    my $now_dow          = $date->day_of_week;
    my $now_year         = $date->year;
    my @daily_duration;

    # weekly contract
    my $first_day_of_week      = $date->truncate_to_day->minus_time_interval($now_dow - 1 . 'd');
    my $first_day_of_next_week = $first_day_of_week->plus_time_interval('7d');
    push @daily_duration,
        _get_trade_date_of_daily_window({
            current_date_start => $first_day_of_week,
            next_date_start    => $first_day_of_next_week,
            duration           => '1W',
            underlying         => $underlying,
        });

    # monthly contract
    my $first_day_of_month      = Date::Utility->new('1-' . $date->month_as_string . '-' . $now_year);
    my $first_day_of_next_month = Date::Utility->new('1-' . $date->months_ahead(1));
    push @daily_duration,
        _get_trade_date_of_daily_window({
            current_date_start => $first_day_of_month,
            next_date_start    => $first_day_of_next_month,
            duration           => '1M',
            underlying         => $underlying,
        });

    # quarterly contract
    my $current_quarter_month     = $date->quarter_of_year * 3 - 2;
    my $first_day_of_quarter      = Date::Utility->new($now_year . "-$current_quarter_month-01");
    my $first_day_of_next_quarter = Date::Utility->new('1-' . $first_day_of_quarter->months_ahead(3));
    push @daily_duration,
        _get_trade_date_of_daily_window({
            current_date_start => $first_day_of_quarter,
            next_date_start    => $first_day_of_next_quarter,
            duration           => '3M',
            underlying         => $underlying,
        });

    # yearly contract
    my $first_day_of_year      = Date::Utility->new($now_year . "-01-01");
    my $first_day_of_next_year = Date::Utility->new('1-' . $first_day_of_year->months_ahead(12));
    push @daily_duration,
        _get_trade_date_of_daily_window({
            current_date_start => $first_day_of_year,
            next_date_start    => $first_day_of_next_year,
            duration           => '1Y',
            underlying         => $underlying,
        });

    # This is for 0 day contract
    my $start_of_day = $date->truncate_to_day;
    my $close_of_day = $trading_calendar->closing_on($underlying->exchange, $date);
    push @daily_duration,
        {
        date_start => {
            date  => $start_of_day->datetime,
            epoch => $start_of_day->epoch,
        },
        date_expiry => {
            date  => $close_of_day->datetime,
            epoch => $close_of_day->epoch,
        },
        duration => '0d'
        };
    return @daily_duration;
}

=head2 _get_intraday_window

To get the intraday trading window of a trading duration. Start at 15 minute before the date_start

=cut

sub _get_intraday_window {
    my $args             = shift;
    my $date_start       = $args->{date_start};
    my $duration         = $args->{duration};
    my $underlying       = $args->{underlying};
    my $exchange         = $underlying->exchange;
    my $trading_calendar = _trading_calendar($underlying->for_date);
    my $now              = $args->{now};
    my $is_early_close   = $trading_calendar->closes_early_on($exchange, $now);

    # If it is early close on the day before, it should start at 00GMT.
    my $start_at_00 = (
               $date_start->day_of_week == 1
            or $trading_calendar->closes_early_on($exchange, $date_start->minus_time_interval('1d'))) && $date_start->hour == 0;
    my $early_date_start = $start_at_00 ? $date_start : $date_start->minus_time_interval('15m');
    my $date_expiry = $date_start->hour == 22 ? $date_start->plus_time_interval('1h59m59s') : $date_start->plus_time_interval($duration);

    if ($is_early_close and $is_early_close->is_before($date_expiry)) {
        return;
    }
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
            duration => $duration . (!$start_at_00 ? '15m' : ''),
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
    my $underlying              = $args->{underlying};
    my $exchange                = $underlying->exchange;
    my $trading_calendar        = _trading_calendar($underlying->for_date);
    my $date_start =
          $trading_calendar->trades_on($exchange, $start_of_current_window)
        ? $start_of_current_window
        : $trading_calendar->trade_date_after($exchange, $start_of_current_window);
    my $date_expiry = $trading_calendar->closing_on($exchange, $trading_calendar->trade_date_before($exchange, $start_of_next_window));

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

sub _get_offerings {
    my ($symbol, $landing_company) = @_;

    my $flyby = _flyby($landing_company);

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

    return map { $_->{barriers} = Finance::Contract::Category->new($_->{contract_category})->two_barriers ? 2 : 1; $_ }
        grep { $supported_contract_types{$_->{contract_type}} } @offerings;
}
1;
