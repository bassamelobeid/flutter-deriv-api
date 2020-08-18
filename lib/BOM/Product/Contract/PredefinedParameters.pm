package BOM::Product::Contract::PredefinedParameters;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK =
    qw(get_predefined_barriers_by_contract_category get_expired_barriers get_available_barriers get_trading_periods generate_barriers_for_window generate_trading_periods next_generation_epoch);

use Encode;
use JSON::MaybeXS;
use Time::HiRes;
use Date::Utility;
use List::Util qw(first min max);
use Math::CDF qw(qnorm);
use Format::Util::Numbers qw/roundcommon/;

use Quant::Framework;
use Finance::Contract::Category;
use LandingCompany::Registry;

use BOM::MarketData qw(create_underlying);
use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;

my $cache_namespace = 'predefined_parameters';
my $json            = JSON::MaybeXS->new;

sub _trading_calendar {
    my $for_date = shift;

    return Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader($for_date), $for_date);
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
    my @key      = trading_period_key($underlying->symbol, $date);
    my $cache    = BOM::Config::Chronicle::get_chronicle_reader($for_date)->$method(@key, $for_date);

    return $cache if $cache;

    # just in case the trading period generation is not quick enough, we don't want to return an empty list on production
    return generate_trading_periods($underlying->symbol, $date);
}

=head2 generate_trading_periods

Generates and returns an array reference of trading period for an underlying symbol.
Each trading period a hash reference with the following keys:

 - date_start
 - date_expiry
 - duration

->generate_trading_periods('frxUSDJPY'); # generates latest trading period
->generate_trading_periods('frxUSDJPY', $date); # generates trading period based on historical conditions

Generation algorithm are based on the Japan regulators' requirements:
Intraday trading period is from 00 GMT to 18 GMT. We offer two intraday windows at any given time:
1) 2-hour window:
- 00:15-02:15, 02:15-04:15, 04:15-06:15, 06:15-08:15, 08:15-10:15 ... 16:15-18:15
2) 6-hour window:
- 00:15-06:15, 06:15-12:15, 12:15-18:15
Daily contract:
1) Daily contract: Start at 00:00GMT and end at 23:59:59GMT of the day
2) Weekly contract: Start at 00:00GMT first trading day of the week and end at the close of last trading day of the week
3) Monthly contract: Start at 00:00GMT of the first trading day of the calendar month and end at the close of the last trading day of the month
4) Quarterly contract: Start at 00:00GMT of the first trading day of the quarter and end at the close of the last trading day of the quarter.
5) Yearly contract: Start at 00:00GMT of the first trading day of the year and end at the close of the last trading day of the year.

=cut

sub generate_trading_periods {
    my ($symbol, $date) = @_;

    my $underlying       = create_underlying($symbol, $date);
    my $trading_calendar = _trading_calendar($date);
    $date //= Date::Utility->new;

    return [] unless $trading_calendar->trades_on($underlying->exchange, $date);

    my @trading_periods  = _get_daily_trading_window($underlying, $date);
    my @intraday_periods = _get_intraday_trading_window($underlying, $date);
    push @trading_periods, @intraday_periods if @intraday_periods;

    return \@trading_periods;
}

sub trading_period_key {
    my ($underlying_symbol, $date) = @_;

    my $key = join '_', ('trading_period', $underlying_symbol, $date->date, $date->hour);
    return ($cache_namespace, $key);
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
    my $cache       = BOM::Config::Redis::redis_replicated_read()->get($cache_namespace . '::' . $highlow_key);

    return @{$json->decode($cache)} if ($cache);
    return ();
}

=head2 next_generation_interval
Always the even hour and even hour 15 minutes, e.g. 00:15:00, 02:00:00, 02:15:00.
=cut

sub next_generation_epoch {
    my $from_date = shift;

    my $hour         = $from_date->hour;
    my $odd_hour     = ($hour % 2);
    my $current_hour = $from_date->truncate_to_day->plus_time_interval($hour . 'h');
    return $current_hour->plus_time_interval('1h')->epoch if $odd_hour;

    my $minute = $from_date->minute;
    return $current_hour->plus_time_interval('15m')->epoch if $minute < 15;
    return $current_hour->plus_time_interval('2h')->epoch;
}

=head2 get_expired_barriers

Get the expired barriers for a specific underlying and trading windows.

Returns an array reference.

=cut

sub get_expired_barriers {
    my ($underlying, $available_barriers, $trading_period) = @_;

    my ($high, $low) = _get_predefined_highlow($underlying, $trading_period);

    # high/low cache is generated based on the availability of ticks for a particular underlying.
    # we only warn if we have tick after the start of the trading window and the high/low cache is undefined.
    # We must know used Distributor::QUOTE to decide if a barrier has expired or not since these ticks are
    # not considered as official ticks in our system.
    if (not($high and $low)) {
        warn "highlow is undefined for "
            . $underlying->symbol . " ["
            . Date::Utility->new($trading_period->{date_start}->{epoch})->datetime . ' - '
            . Date::Utility->new($trading_period->{date_expiry}->{epoch})->datetime . "]"
            if ($underlying->spot_tick->epoch >= $trading_period->{date_start}->{epoch});
        return [];
    }

    my @expired_barriers;
    foreach my $barrier (@$available_barriers) {
        my $ref_barrier = (ref $barrier ne 'ARRAY') ? [$barrier] : $barrier;
        my @expired     = grep { $_ <= $high && $_ >= $low } @$ref_barrier;
        push @expired_barriers, $barrier if @expired;
    }

    return \@expired_barriers;
}

=head2 get_avalable_barriers

Get the available barriers for a specific underlying, trading period & offerings combination.

Returns an array reference

=cut

sub get_available_barriers {
    my ($underlying, $offering, $trading_period) = @_;

    my $date               = $underlying->for_date // Date::Utility->new;
    my $method             = $underlying->for_date ? 'get_for' : 'get';
    my $available_barriers = [];
    my ($namespace, $key) = predefined_barriers_key($underlying->symbol, $trading_period);
    my $barriers = BOM::Config::Chronicle::get_chronicle_reader($underlying->for_date)->$method($namespace, $key, $date);

    return $available_barriers unless $barriers;

    if ($offering->{barriers} == 1) {
        # only 2h and 6h uses shortterm barriers
        if ($trading_period->{duration} =~ /^(2|6)h$/) {
            my $atm_barrier = $barriers->{50};
            # JPY pairs has pip size defined at the 2nd digit after decimal.
            # Non-JPY pairs has pip size defined at the 4th digit after decimal.
            my $pip_size_at   = $underlying->symbol =~ /JPY/ ? 0.01 : 0.0001;
            my $minimum_step  = $pip_size_at * 5;                                    # 5 pips interval for barriers
            my $barrier_count = barrier_count_for_underlying($underlying->symbol);
            die 'barrier count is undefined for ' . $underlying->symbol unless defined $barrier_count;
            my @barriers;
            for (1 .. $barrier_count) {
                my $high_barrier = $atm_barrier + $_ * $minimum_step;
                my $low_barrier  = $atm_barrier - $_ * $minimum_step;
                push @barriers, $high_barrier, $low_barrier;
            }
            push @barriers, $atm_barrier if $offering->{barrier_category} ne 'american';
            $available_barriers = [map { $underlying->pipsized_value($_) } sort { $a <=> $b } @barriers];
        } else {
            my @deltas = (5, 15, 25, 38, 62, 75, 85, 95);
            push @deltas, 50 if $offering->{barrier_category} ne 'american';
            $available_barriers = [map { $underlying->pipsized_value($barriers->{$_}) } sort { $a <=> $b } @deltas];
        }
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

my %count = (
    frxAUDJPY => 2,
    frxAUDUSD => 2,
    frxEURGBP => 2,
    frxUSDJPY => 3,
    frxEURUSD => 3,
    frxEURJPY => 3,
    frxGBPJPY => 3,
    frxUSDCAD => 3,
    frxGBPUSD => 3,
);

sub barrier_count_for_underlying {
    my $symbol = shift;
    return $count{$symbol} // 2;
}

=head2 generate_barriers_for_window

Generates a set of predefined contract barriers for a specific underlying and trading window.

Barriers are generated from 0.25 delta to 0.75 delta with a 0.05 increment.

Returns a hash reference.

=cut

sub generate_barriers_for_window {
    my ($symbol, $trading_period) = @_;

    unless ($trading_period->{date_start}->{epoch} and $trading_period->{date_expiry}->{epoch}) {
        die 'Trading period is not in the correct format. date_start and date_expiry epochs are required';
    }

    my $key   = join '_', ('barriers', $symbol, $trading_period->{date_start}->{epoch}, $trading_period->{date_expiry}->{epoch});
    my $cache = BOM::Config::Redis::redis_replicated_read()->get($cache_namespace . '::' . $key);

    # return if barriers are generated already
    return if $cache;

    my $tiy = ($trading_period->{date_expiry}->{epoch} - $trading_period->{date_start}->{epoch}) / (365 * 86400);

    my $underlying       = create_underlying($symbol);
    my $spot_at_start    = _get_spot($underlying, $trading_period);
    my @initial_barriers = map { _get_strike_from_call_bs_price($_, $tiy, $spot_at_start, 0.1) } (0.05, 0.95);

    # Split the boundaries barriers into 9 barriers by divided the distance of boundaries by 95 (45 each side) - to be used as increment.
    # The barriers will be split in the way more cluster towards current spot and gradually spread out from current spot.
    # Included entry spot as well
    my $distance_between_boundaries = abs($initial_barriers[0] - $initial_barriers[1]);
    my @steps                       = (12, 25, 35, 45);
    my $minimum_step                = roundcommon($underlying->pip_size, $distance_between_boundaries / ($steps[-1] * 2));
    my %barriers                    = map { (50 - $_ => $spot_at_start - $_ * $minimum_step, 50 + $_ => $spot_at_start + $_ * $minimum_step) } @steps;
    $barriers{50} = $spot_at_start;

    return \%barriers;
}

sub predefined_barriers_key {
    my ($symbol, $trading_period) = @_;

    unless ($trading_period->{date_start}->{epoch} and $trading_period->{date_expiry}->{epoch}) {
        die 'Trading period is not in the correct format. date_start and date_expiry epochs are required';
    }

    my $key = join '_', ('barriers', $symbol, $trading_period->{date_start}->{epoch}, $trading_period->{date_expiry}->{epoch});
    return ($cache_namespace, $key);
}

sub barrier_by_category_key {
    my $symbol = shift;

    my $key = $symbol . '_barriers_by_category';
    return ($cache_namespace, $key);
}

sub get_predefined_barriers_by_contract_category {
    my ($symbol, $date) = @_;

    my $method = $date ? 'get_for' : 'get';
    my ($namespace, $key) = barrier_by_category_key($symbol);

    return BOM::Config::Chronicle::get_chronicle_reader($date)->$method($namespace, $key, $date);
}

sub _get_spot {
    my ($underlying, $trading_period) = @_;
    my $spot;
    my ($source, $quote) = ('unknown', 'unknown');
    my $date_start = Date::Utility->new($trading_period->{date_start}->{epoch});

    my $now = time;
    my $tick_from_distributor_redis;
    my $redis = BOM::Config::Redis::redis_replicated_read();
    my $redis_tick_json;
    my $redis_tick_from_date_start;

    # Distributor::QUOTE is only used as a relative reference to barrier calculation so that we will
    # have valid predefined barriers if previous day is a non-trading day (e.g. on Monday morning).
    # This is to avoid using ticks on the previous trading day's close as spot prices may differ by a lot.
    if ($redis_tick_json = $redis->get('Distributor::QUOTE::' . $underlying->symbol)) {
        $tick_from_distributor_redis = $json->decode(Encode::decode_utf8($redis_tick_json));
        $redis_tick_from_date_start  = $date_start->epoch - $tick_from_distributor_redis->{epoch};
    }
    my $tick_from_feeddb = $underlying->tick_at($trading_period->{date_start}->{epoch}, {allow_inconsistent => 1});
    my $outdated_feeddb;
    unless ($tick_from_feeddb) {
        # If spot at requested time is not present, we will use current spot.
        # This should not happen in production, it is for QA purposes.
        warn "using current tick to calculate barrier for period [$trading_period->{date_start}->{date} - $trading_period->{date_expiry}->{date}]"
            unless $tick_from_distributor_redis;
        $tick_from_feeddb = $underlying->spot_tick;
        $outdated_feeddb  = 1;
    }
    my $feeddb_tick_from_date_start = $date_start->epoch - $tick_from_feeddb->epoch;

    # We will compare the most recent tick from feedbd and also provider's redis and take the most recent one
    if (defined $tick_from_distributor_redis and $redis_tick_from_date_start >= 0 and $redis_tick_from_date_start < $feeddb_tick_from_date_start) {
        $spot   = $tick_from_distributor_redis->{quote};
        $source = 'redis';
        $quote  = $redis_tick_json;

    } else {
        $spot   = $tick_from_feeddb->quote;
        $source = $outdated_feeddb ? 'feed-db:outdated' : 'feeddb';
        $quote  = Encode::encode_utf8($json->encode($tick_from_feeddb->as_hash));
    }

    if (!defined $spot) {
        die 'Could not retrieve tick for ' . $underlying->symbol . ' at ' . $date_start->datetime;
    }
    print __PACKAGE__ . " $0 [barriers-debug] :: $spot from $source ( $quote ) at $now \n";
    return $spot;
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

# Intraday predefined trading window are as follow:
#
# Intraday trading period is from 00 GMT to 18 GMT. We offer two intraday windows at any given time:
# - 2-hour window
# - 6-hour window
#
# 2-hour window:
# - 00:15:00-02:15:00, 02:15:00-04:15:00, 04:15:00-06:15:00, 06:15:00-08:15:00, ... 16:15:00-18:15:00
#
# 6-hour window:
# - 00:15:00-06:15:00, 06:15:00-12:15:00, 12:15:00-18:15:00
#

sub _fixed_windows {
    my $date = shift;

    my $start_of_trading = $date->truncate_to_day->plus_time_interval('15m');
    my $end_of_trading   = $date->truncate_to_day->plus_time_interval('18h15m');

    my %windows;
    foreach my $interval (2, 6) {
        my $window_start = $start_of_trading;
        while ($window_start->is_before($end_of_trading)) {
            my $window_end = $window_start->plus_time_interval($interval . 'h');
            if ($date->epoch >= $window_start->epoch and $date->epoch < $window_end->epoch) {
                $windows{$interval} = [$window_start, $window_end];
                last;
            }
            $window_start = $window_end;
        }
    }

    return \%windows;
}

sub _get_intraday_trading_window {
    my ($underlying, $date) = @_;

    my $tc            = _trading_calendar($underlying->for_date);
    my $fixed_windows = _fixed_windows($date);

    return () unless %$fixed_windows;

    my @windows = ();
    # 2-hour window & 6-hour window
    foreach my $interval (2, 6) {
        my $window = $fixed_windows->{$interval};
        next unless $window;
        my ($start_of_interval, $end_of_interval) = map { $window->[$_] } (0, 1);

        if ($tc->is_open_at($underlying->exchange, $end_of_interval) && $date->is_before($end_of_interval)) {
            push @windows,
                +{
                date_start => {
                    date  => $start_of_interval->datetime,
                    epoch => $start_of_interval->epoch
                },
                date_expiry => {
                    date  => $end_of_interval->datetime,
                    epoch => $end_of_interval->epoch,
                },
                duration => $interval . 'h',
                };
        }
    }

    return @windows;
}

=head2 _get_daily_trading_window
To get the end of day, weekly, monthly , quarterly, and yearly trading window.
=cut

sub _get_daily_trading_window {
    my ($underlying, $date) = @_;

    my $now_dow  = $date->day_of_week;
    my $now_year = $date->year;
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

    return @daily_duration;
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

1;
