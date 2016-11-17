package BOM::Product::Contract::PredefinedParameters;

use Exporter qw(import);
our @EXPORT_OK = qw(generate_predefined_offerings get_predefined_offerings update_predefined_highlow);

use Date::Utility;
use List::Util qw(first min max);
use Math::CDF qw(qnorm);
use Format::Util::Numbers qw(roundnear);
use LandingCompany::Offerings qw(get_offerings_flyby);

use BOM::Product::Contract::Category;
use BOM::MarketData qw(create_underlying);
use BOM::System::Chronicle;

my $cache_namespace = 'predefined_parameters';

sub update_predefined_highlow {
    my $tick_data = shift;

    my $underlying = create_underlying($tick_data->{symbol});
    my $now        = $tick_data->{epoch};
    my $offerings  = get_predefined_offerings($underlying);
    my $new_quote  = $tick_data->{price};

    return unless @$offerings;

    foreach my $offering (@$offerings) {
        next if ($offering->{barrier_category} ne 'american');
        my $period          = $offering->{trading_period};
        my $key             = join '_', ('highlow', $underlying->symbol, $period->{date_start}->{epoch}, $period->{date_expiry}->{epoch});
        my $current_highlow = BOM::System::Chronicle::get_chronicle_reader()->get($cache_namespace, $key);
        my ($new_high, $new_low);

        if ($current_highlow) {
            my ($high, $low) = map { $current_highlow->[$_] } (0, 1);
            $new_high = max($tick_data->{price}, $high);
            $new_low = min($tick_data->{price}, $low);
        } else {
            my $db_highlow = $underlying->get_high_low_for_period({
                start => $period->{date_start}->{epoch},
                end   => $now,
            });
            $new_high = max($tick_data->{price}, $db_highlow->{high});
            $new_low = min($tick_data->{price}, $db_highlow->{low});
        }

        my $ttl = max(0, $period->{date_expiry}->{epoch} - $now);
        BOM::System::Chronicle::get_chronicle_writer()->set($cache_namespace, $key, [$new_high, $new_low], Date::Utility->new, $ttl);
    }

    return 1;
}

sub generate_predefined_offerings {
    my ($symbol, $for_date) = @_;

    my @offerings = _get_offerings($symbol);
    my $underlying = create_underlying($symbol, $for_date);

    $for_date = Date::Utility->new unless $for_date;

    return [] unless $underlying->calendar->trades_on($for_date);

    # we perform two things here:
    # - split offerings into applicable trading periods.
    # - calculate barriers.
    my @new_offerings = _apply_predefined_parameters($for_date, $underlying, \@offerings);

    my $key = join '_', ('offerings', $underlying->symbol, $for_date->date, $for_date->hour);
    BOM::System::Chronicle::get_chronicle_writer()->set($cache_namespace, $key, \@new_offerings);

    return \@new_offerings;
}

sub get_predefined_offerings {
    my $underlying = shift;

    my $for_date = $underlying->for_date // Date::Utility->new;
    my $key       = join '_', ('offerings', $underlying->symbol, $for_date->date, $for_date->hour);
    my $reader    = BOM::System::Chronicle::get_chronicle_reader;
    my $offerings = $underlying->for_date ? $reader->get_for($cache_namespace, $key, $for_date) : $reader->get($cache_namespace, $key);

    return $offerings // [];
}

sub _get_trading_periods {
    my ($for_date, $underlying) = @_;

    my @trading_periods = _get_daily_trading_window($underlying, $for_date);
    my @intraday_periods = _get_intraday_trading_window($underlying, $for_date);
    push @trading_periods, @intraday_periods if @intraday_periods;

    return \@trading_periods;
}

sub _apply_predefined_parameters {
    my ($for_date, $underlying, $offerings) = @_;

    my $trading_periods = _get_trading_periods($for_date, $underlying);

    return () unless @$trading_periods;

    my $close_epoch = $underlying->calendar->closing_on($for_date)->epoch;
    # full trading seconds
    my $trading_seconds = $close_epoch - $for_date->truncate_to_day->epoch;

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
            } elsif ($for_date->day_of_week == 5
                and $trading_duration < 86400
                and ($date_expiry > $close_epoch or $date_start > $close_epoch))
            {
                next;
            } else {
                my $start_tick = $underlying->tick_at($date_start)
                    or die 'Could not get spot for ' . $symbol . ' at ' . Date::Utility->new($date_start)->datetime;

                my $barriers = _calculate_barriers({
                    underlying      => $underlying,
                    call_prices     => [0.02, 0.98],
                    trading_periods => $trading_period,
                });

                my $available_barriers;
                if ($offering->{barriers} == 1) {
                    $available_barriers = [sort { $a <=> $b } values %$barriers];
                } elsif ($offering->{barriers} == 2) {
                    # For staysinout contract, we need to pair the barriers symmetry, ie (42, 58), (34,66), (26,74), (18,82)
                    # For endsinout contract, we need to pair barriers as follow: (42,58), (34,50), (50,66), (26,42), (58,74), (18,34), (66,82), (2, 26), (74, 98)
                    # Note: 42 is -8d from the spot at start and 58 is +8d from spot at start
                    # where d is the minimum increment that determine by divided the distance of boundaries by 96 (48 each side)
                    my @barrier_pairs =
                        $offering->{contract_category} eq 'staysinout'
                        ? ([42, 58], [34, 66], [26, 74], [18, 82])
                        : ([42, 58], [34, 50], [50, 66], [26, 42], [58, 74], [18, 34], [66, 82], [2, 26], [74, 98]);

                    $available_barriers = [map { [$barriers->{$_->[0]}, $barriers->{$_->[1]}] } @barrier_pairs];
                }

                push @new_offerings,
                    +{
                    %{$offering},
                    trading_period     => $trading_period,
                    available_barriers => $available_barriers
                    };
            }
        }
    }

    return @new_offerings;
}

sub _calculate_barriers {
    my $args = shift;

    my ($underlying, $call_prices, $trading_period) = @{$args}{qw(underlying call_prices trading_periods)};
    my $tick = $underlying->tick_at($trading_period->{date_start}->{epoch})
        or die 'Could not retrieve tick for ' . $underlying->symbol . ' at ' . Date::Utility->new($trading_period->{date_start}->{epoch});
    my $spot_at_start = $tick->quote;
    my $tiy = ($trading_period->{date_expiry}->{epoch} - $trading_period->{date_start}->{epoch}) / (365 * 86400);

    my @initial_barriers = map { _get_strike_from_call_bs_price($_, $tiy, $spot_at_start, 0.1) } (0.02, 0.98);

    # Split the boundaries barriers into 10 barriers by divided the distance of boundaries by 96 (48 each side) - to be used as increment.
    # The barriers will be split in the way more cluster towards current spot and gradually spread out from current spot.
    # Included entry spot as well
    my $distance_between_boundaries = abs($initial_barriers[0] - $initial_barriers[1]);
    my @steps                       = (8, 16, 24, 32, 48);
    my $minimum_step                = roundnear($underlying->pip_size, $distance_between_boundaries / ($steps[-1] * 2));
    my %barriers                    = map { (50 - $_ => $spot_at_start - $_ * $minimum_step, 50 + $_ => $spot_at_start + $_ * $minimum_step) } @steps;
    $barriers{50} = $spot_at_start;

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
# 00:00-02:00,01:45-04:00, 03:45-06:00, 05:45-08:00, 0745-10:00,09:45-12:00, 11:45-14:00, 13:45-16:00, 15:45-18:00 21:45:00, 23:45-02:00,01:45-04:00, 03:45-06:00
#
# 5 hours and 15 min duration:
# 00:45-06:00 ; 04:45-10:00 ; 08:45-14:00 ; 12:45-18:00
#
# Hence, we will generate the window at HH::45 (HH is the predefined trading hour) to include any new trading window and will also generate the trading window again at the next HH:00 to remove any expired trading window.

sub _get_intraday_trading_window {
    my ($underlying, $for_date) = @_;

    my $start_of_day = $for_date->truncate_to_day;
    my ($hour, $minute, $date_str) = ($for_date->hour, $for_date->minute, $for_date->date);

    $hour = $minute < 45 ? $hour : $hour + 1;
    my $even_hour = $hour - ($hour % 2);
    # We did not offer intraday contract after NY16. However, we turn on these three pairs on Japan
    my @skips_hour = (first { $_ eq $underlying->symbol } qw(frxUSDJPY frxAUDJPY frxAUDUSD)) ? (18, 20) : (18, 20, 22);
    my $skips_intraday = first { $even_hour == $_ } @skips_hour;

    return () if $skips_intraday;

    my @intraday_windows;

    my $window_2h = _get_intraday_window({
        now        => $for_date,
        date_start => $start_of_day->plus_time_interval($even_hour . 'h'),
        duration   => '2h'
    });

    # Previous 2 hours contract should be always available in the first 15 minutes of the next one
    # (except start of the trading day and also the first window after the break)
    if (($for_date->epoch - $window_2h->{date_start}->{epoch}) / 60 < 15 && $even_hour - 2 >= 0 && $even_hour != 22) {
        push @intraday_windows,
            _get_intraday_window({
                now        => $for_date,
                date_start => $start_of_day->plus_time_interval(($even_hour - 2) . 'h'),
                duration   => '2h'
            });
    }

    push @intraday_windows, $window_2h;

    my $odd_hour = ($hour % 2) ? $hour : $hour - 1;
    $odd_hour = $odd_hour % 4 == 1 ? $odd_hour : $odd_hour - 2;

    if ($hour > 0 and $hour < 18 and $odd_hour != 21) {
        push @intraday_windows, map { _get_intraday_window({now => $for_date, date_start => $_, duration => '5h'}) }
            grep { $_->is_after($start_of_day) }
            map { $start_of_day->plus_time_interval($_ . 'h') } ($odd_hour, $odd_hour - 4);
    }

    return @intraday_windows;
}

=head2 _get_daily_trading_window

To get the end of day, weekly, monthly , quarterly, and yearly trading window.

=cut

sub _get_daily_trading_window {
    my ($underlying, $for_date) = @_;

    my $calendar = $underlying->calendar;
    my $now_dow  = $for_date->day_of_week;
    my $now_year = $for_date->year;
    my @daily_duration;

    # weekly contract
    my $first_day_of_week      = $for_date->truncate_to_day->minus_time_interval($now_dow - 1 . 'd');
    my $first_day_of_next_week = $first_day_of_week->plus_time_interval('7d');
    push @daily_duration,
        _get_trade_date_of_daily_window({
            current_date_start => $first_day_of_week,
            next_date_start    => $first_day_of_next_week,
            duration           => '1W',
            calendar           => $calendar
        });

    # monthly contract
    my $first_day_of_month      = Date::Utility->new('1-' . $for_date->month_as_string . '-' . $now_year);
    my $first_day_of_next_month = Date::Utility->new('1-' . $for_date->months_ahead(1));
    push @daily_duration,
        _get_trade_date_of_daily_window({
            current_date_start => $first_day_of_month,
            next_date_start    => $first_day_of_next_month,
            duration           => '1M',
            calendar           => $calendar
        });

    # quarterly contract
    my $current_quarter_month     = $for_date->quarter_of_year * 3 - 2;
    my $first_day_of_quarter      = Date::Utility->new($now_year . "-$current_quarter_month-01");
    my $first_day_of_next_quarter = Date::Utility->new('1-' . $first_day_of_quarter->months_ahead(3));
    push @daily_duration,
        _get_trade_date_of_daily_window({
            current_date_start => $first_day_of_quarter,
            next_date_start    => $first_day_of_next_quarter,
            duration           => '3M',
            calendar           => $calendar
        });

    # This is for 0 day contract
    my $start_of_day = $for_date->truncate_to_day;
    my $close_of_day = $calendar->closing_on($for_date);
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
    my $now              = $args->{now};
    my $is_monday_start  = $now->day_of_week == 1 && $date_start->hour == 0;
    my $early_date_start = $is_monday_start ? $date_start : $date_start->minus_time_interval('15m');
    my $date_expiry      = $date_start->hour == 22 ? $date_start->plus_time_interval('1h59m59s') : $date_start->plus_time_interval($duration);
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
            duration => $duration . (!$is_monday_start ? '15m' : ''),
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
    my $calendar                = $args->{calendar};
    my $date_start =
        $calendar->trades_on($start_of_current_window) ? $start_of_current_window : $calendar->trade_date_after($start_of_current_window);
    my $date_expiry = $calendar->closing_on($calendar->trade_date_before($start_of_next_window));

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
1;
