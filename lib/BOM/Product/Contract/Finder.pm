## no critic (ValuesAndExpressions::ProhibitCommaSeparatedStatements)

package BOM::Product::Contract::Finder;

use strict;
use warnings;

use Cache::RedisDB;
use Date::Utility;
use Time::Duration::Concise;
use VolSurface::Utils qw(get_strike_for_spot_delta);

use BOM::Market::Underlying;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Product::Contract::Category;
use BOM::Product::Contract::Strike;

use base qw( Exporter );
our @EXPORT_OK = qw(available_contracts_for_symbol);

sub available_contracts_for_symbol {
    my $args                = shift;
    my $symbol              = $args->{symbol} || die 'no symbol';
    my $predefined_contract = $args->{predefined} || '';

    my $now          = Date::Utility->new;
    my $underlying   = BOM::Market::Underlying->new($symbol);
    my $exchange     = $underlying->exchange;
    my $open         = $exchange->opening_on($now)->epoch;
    my $close        = $exchange->closing_on($now)->epoch;
    my $current_tick = $underlying->spot_tick // $underlying->tick_at($now->epoch, {allow_inconsistent => 1});
    my $flyby        = BOM::Product::Offerings::get_offerings_flyby;
    my @offerings    = $flyby->query({underlying_symbol => $symbol});

    if ($predefined_contract) {
        @offerings = _predefined_trading_period({
            offerings => \@offerings,
            exchange  => $exchange
        });
    }

    for my $o (@offerings) {
        my $cc = $o->{contract_category};
        my $bc = $o->{barrier_category};

        my $cat = BOM::Product::Contract::Category->new($cc);
        $o->{contract_category_display} = $cat->display_name;

        if ($o->{start_type} eq 'forward') {
            my @trade_dates;
            for (my $date = $now; @trade_dates < 3; $date = $date->plus_time_interval('1d')) {
                $date = $exchange->trade_date_after($date) unless $exchange->trades_on($date);
                push @trade_dates, $date;
            }
            $o->{forward_starting_options} =
                [map { {date => $_->epoch, open => $exchange->opening_on($_)->epoch, close => $exchange->closing_on($_)->epoch} } @trade_dates];
        }

        $o->{barriers} =
              $cat->two_barriers    ? 2
            : $cc eq 'asian'        ? 0
            : $cc eq 'digits'       ? 1
            : $cc eq 'touchnotouch' ? 1
            : $cc eq 'callput'      ? (
              $bc eq 'euro_atm'     ? 0
            : $bc eq 'euro_non_atm' ? 1
            :                         die "don't know about callput / $bc combo"
            )
            : die "don't know about contract category $cc";

        # get the closest from spot barrier from the predefined set
        if ($predefined_contract) {
            $o->{barriers} = $bc eq 'euro_atm' ? 1 : $o->{barriers};
            $o->{available_barriers} = _predefined_barriers_on_trading_period({
                underlying => $underlying,
                contract   => $o
            });

            if ($o->{barriers} == 1) {
                my @barriers = sort { abs($current_tick->quote - $a) <=> abs($current_tick->quote - $b) } @{$o->{available_barriers}};
                $o->{barrier} = $barriers[0];
            } elsif ($o->{barriers} == 2) {
                my @barriers2 = sort { abs($current_tick->quote - $a->[0]) <=> abs($current_tick->quote - $b->[0]) } @{$o->{available_barriers}};
                $o->{high_barrier} = $barriers2[0][0];
                $o->{low_barrier}  = $barriers2[0][1];
            }
        } else {

            if ($o->{barriers}) {
                my $min_duration = Time::Duration::Concise->new(interval => $o->{min_contract_duration})->seconds;
                my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying});
                my $atm_vol = $volsurface->get_volatility({
                    delta => 50,
                    days  => $min_duration / 86400,
                });

                if ($o->{barriers} == 1) {
                    $o->{barrier} = _get_barrier({
                        underlying    => $underlying,
                        duration      => $min_duration,
                        direction     => 'high',
                        barrier_delta => 0.2,
                        barrier_tick  => $current_tick,
                        atm_vol       => $atm_vol
                    });
                }

                if ($o->{barriers} == 2) {
                    $o->{high_barrier} = _get_barrier({
                        underlying    => $underlying,
                        duration      => $min_duration,
                        direction     => 'high',
                        barrier_delta => 0.2,
                        barrier_tick  => $current_tick,
                        atm_vol       => $atm_vol
                    });
                    $o->{low_barrier} = _get_barrier({
                        underlying    => $underlying,
                        duration      => $min_duration,
                        direction     => 'low',
                        barrier_delta => 0.2,
                        barrier_tick  => $current_tick,
                        atm_vol       => $atm_vol
                    });
                }
            }
        }
    }

    return {
        available => \@offerings,
        hit_count => scalar(@offerings),
        open      => $open,
        close     => $close,
    };
}

sub _get_barrier {
    my $args = shift;

    my ($underlying, $duration, $direction, $barrier_delta, $barrier_tick, $absolute_barrier, $atm_vol) =
        @{$args}{'underlying', 'duration', 'direction', 'barrier_delta', 'barrier_tick', 'absolute_barrier', 'atm_vol'};

    my $approximate_barrier = get_strike_for_spot_delta({
        option_type => ($direction eq 'low') ? 'VANILLA_CALL' : 'VANILLA_PUT',
        delta       => $barrier_delta,
        atm_vol     => $atm_vol,
        t => $duration / (86400 * 365),
        r_rate           => 0,
        q_rate           => 0,
        spot             => $barrier_tick->quote,
        premium_adjusted => 0,
    });
    my $strike = BOM::Product::Contract::Strike->new(
        underlying       => $underlying,
        basis_tick       => $barrier_tick,
        supplied_barrier => $approximate_barrier,
    );

    return ($absolute_barrier or $duration > 86400) ? $strike->as_absolute : $strike->as_relative;
}

=head2 _predefined_trading_period

We set the predefined trading periods based on Japan requirement:
1) Start at 00:00GMT and expire with duration of 2,4,6,8,12,16,20 hours
2) Start at closest even hour and expire with duration of 2 hours. Example: Current hour is 3GMT, you will have trading period of 02-04GMT.
3) Start at 00:00GMT and expire with duration of 1,2,3,7,30,60,180,365 days

=cut

my $cache_keyspace = 'PREDEFINED_TRADING_PERIOD';

sub _predefined_trading_period {
    my $args      = shift;
    my @offerings = @{$args->{offerings}};
    my $exchange  = $args->{exchange};

    my $period_length = Time::Duration::Concise->new({interval => '2h'});    # Two hour intraday rolling periods.
    my $now           = Date::Utility->new;
    my $in_period     = $now->hour - ($now->hour % $period_length->hours);

    my $trading_key = join('==', $exchange->symbol, $now->date, $in_period);
    my $trading_periods = Cache::RedisDB->get($cache_keyspace, $trading_key);

    if (not $trading_periods) {
        my $today        = $now->truncate_to_day;                            # Start of the day object.
        my $start_of_day = $today->datetime;                                 # As a string.

        # Starting at midnight, running through these times.
        my @hourly_durations = qw(2h 4h 6h 8h 12h 16h 20h);

        $trading_periods = [
            map { +{date_start => $start_of_day, date_expiry => $_->datetime} }
            grep { $now->is_before($_) } map { $today->plus_time_interval($_) } @hourly_durations
        ];

        # Starting at midnight, running through these dates.
        my @daily_durations = qw(1d 2d 3d 7d 30d 60d 180d 365d);
        my %added;

        foreach my $date (map { $today->plus_time_interval($_) } @daily_durations) {
            $date = $exchange->trade_date_after($date) unless ($exchange->trades_on($date));
            my $actual_day_string = $date->days_between($today) . 'd';
            next if ($added{$actual_day_string});    # We already saw this date in a previous iteration.
            $added{$actual_day_string} = 1;
            push @$trading_periods,
                +{
                date_start  => $start_of_day,
                date_expiry => $exchange->closing_on($date)->datetime,
                };
        }
        # Starting in the most recent even hour, running for.our period
        my $period_start = $today->plus_time_interval($in_period . 'h');
        push @$trading_periods,
            +{
            date_start  => $period_start->datetime,
            date_expiry => $period_start->plus_time_interval($period_length)->datetime,
            };

        # We will hold it for the duration of the period which is a little too long, but no big deal.
        Cache::RedisDB->set($cache_keyspace, $trading_key, $trading_periods, $period_length->seconds);
    }

    my @new_offerings;
    foreach my $o (grep { $_->{start_type} eq 'spot' and $_->{expiry_type} ne 'tick' } @offerings) {
        foreach my $trading_period (@$trading_periods) {
            push @new_offerings, {%{$o}, trading_period => $trading_period};
        }
    }

    return @new_offerings;
}

=head2 _predefined_barriers_on_trading_period

To set the predefined barriers on each trading period.
We will take strike from 20, 30 .... 80 delta.

=cut

sub _predefined_barriers_on_trading_period {
    my $args = shift;
    my ($underlying, $contract) = @{$args}{'underlying', 'contract'};

    my $trading_period    = $contract->{trading_period};
    my $date_start        = Date::Utility->new($trading_period->{date_start});
    my $date_expiry       = Date::Utility->new($trading_period->{date_expiry});
    my $barrier_tick      = $underlying->tick_at($date_start->epoch, {allow_inconsistent => 1});
    my $duration          = $date_expiry->epoch - $date_start->epoch;
    my @delta             = (0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8);
    my $number_of_barrier = $contract->{barriers};
    my @available_barriers;

    foreach my $delta (@delta) {
        my $barrier = _get_barrier({
            underlying       => $underlying,
            duration         => $duration,
            direction        => 'high',
            barrier_delta    => $delta,
            barrier_tick     => $barrier_tick,
            absolute_barrier => 1,
            atm_vol          => 0.1
        });
        my $barrier_2;

        if ($number_of_barrier == 1) {
            push @available_barriers, $barrier;
        } else {
            $barrier_2 = _get_barrier({
                underlying       => $underlying,
                duration         => $duration,
                direction        => 'low',
                barrier_delta    => $delta,
                barrier_tick     => $barrier_tick,
                absolute_barrier => 1,
                atm_vol          => 0.1
            });
            push @available_barriers, [$barrier, $barrier_2];
        }
    }

    return \@available_barriers;
}
1;
