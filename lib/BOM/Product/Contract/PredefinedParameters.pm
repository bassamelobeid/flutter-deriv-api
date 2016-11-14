package BOM::Product::Contract::PredefinedParameters;

use Exporter qw(import);
our @EXPORT_OK = qw(get_trading_periods generate_trading_periods);

use Date::Utility;
use List::Util qw(first);

use BOM::MarketData qw(create_underlying);
use BOM::System::Chronicle;

my $cache_namespace = 'trading_periods';

sub get_trading_periods {
    my ($symbol, $for_date) = @_;

    my $historical_request = _is_historical_request($for_date);
    my $chronicle_reader   = BOM::System::Chronicle::get_chronicle_reader($historical_request);
    $for_date = Date::Utility->new unless defined $for_date;
    my $trading_key = _get_key($symbol, $for_date);

    my $trading_periods =
          $historical_request
        ? $chronicle_reader->get_for($cache_namespace, $trading_key, $for_date)
        : $chronicle_reader->get($cache_namespace, $trading_key);

    return $trading_periods // [];
}

sub generate_trading_periods {
    my ($symbol, $for_date) = @_;

    my $chronicle_writer   = BOM::System::Chronicle::get_chronicle_writer();
    my $historical_request = _is_historical_request($for_date);

    # underlying needs a proper for_date to fetch the correct market data.
    my $underlying = $historical_request ? create_underlying($symbol, $for_date) : create_underlying($symbol);

    return [] unless $underlying->calendar->trades_on($for_date);

    my @trading_periods = _get_daily_trading_window($underlying, $for_date);

    my @intraday_periods = _get_intraday_trading_window($for_date);
    push @trading_periods, @intraday_periods if @intraday_periods;

    # TTL is the remaining seconds until the forthcoming HH:45 (if current minute is < 45) or the forthcoming HH:)) (if the current time is >= 45)

    # So cache TTL is (in mins for comfort) :
    # hh:00 => ttl = 45 min
    # hh:03 => ttl = 42 min
    # hh:29 => ttl = 16 min
    # hh:44 => ttl = 1 min
    # hh:45 => ttl = 15 min
    # hh:54 => ttl = 6 min
    # hh:59 => ttl = 1 min
    # hh:00 => ttl = 45 min

    my $minute = $for_date->minute;
    my $ttl = ($minute < 45 ? 2700 : 3600) - $minute * 60 - $for_date->second;
    $chronicle_writer->set($cache_namespace, $trading_key, $ttl);

    return \@trading_periods;
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
    my $for_date = shift;

    my $start_of_day = $for_date->truncate_to_day;
    my ($hour, $minute, $date_str) = ($for_date->hour, $for_date->minute, $for_date->date);

    $hour = $minute < 45 ? $hour : $hour + 1;
    my $even_hour = $hour - ($hour % 2);
    # We did not offer intraday contract after NY16. However, we turn on these three pairs on Japan
    my @skips_hour = (first { $_ eq $symbol } qw(frxUSDJPY frxAUDJPY frxAUDUSD)) ? (18, 20) : (18, 20, 22);
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

sub _is_historical_request {
    my $date = shift;

    return 0 if not defined $date;
    return 1 if $for_date->is_before(Date::Utility->new);
    return 0;
}

sub _get_key {
    my ($symbol, $date) = @_;

    my $key = join('==', $symbol, $date->date, $date->hour);

    return $key;
}

1;
