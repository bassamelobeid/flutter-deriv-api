package BOM::Product::ContractFinder::Basic;

use strict;
use warnings;

use POSIX qw(floor);
use Date::Utility;
use Finance::Contract::Category;
use Time::Duration::Concise;
use VolSurface::Utils qw(get_strike_for_spot_delta);
use Number::Closest::XS qw(find_closest_numbers_around);

use BOM::Product::Contract::Strike;
use BOM::MarketData::Fetcher::VolSurface;

sub decorate {
    my $args = shift;

    my ($underlying, $offerings, $now, $calendar) = @{$args}{'underlying', 'offerings', 'date', 'calendar'};

    my $exchange            = $underlying->exchange;
    my @inefficient_periods = @{$underlying->forward_inefficient_periods // []};
    my $to_date             = $now->truncate_to_day->epoch;
    my @blackout_periods =
        map { [Date::Utility->new($to_date + $_->{start})->time_hhmmss, Date::Utility->new($to_date + $_->{end})->time_hhmmss] } @inefficient_periods;
    my $forward_starting_options;

    for my $o (@$offerings) {
        my $contract_category = $o->{contract_category};
        my $barrier_category  = $o->{barrier_category};
        my $contract_type     = $o->{contract_type};

        if ($o->{start_type} eq 'forward') {
            if (defined $forward_starting_options) {
                $o->{forward_starting_options} = $forward_starting_options;
            } else {
                my @trade_dates;
                for (my $date = $now; @trade_dates < 3; $date = $date->plus_time_interval('1d')) {
                    $date = $calendar->trade_date_after($exchange, $date) unless $calendar->trades_on($exchange, $date);
                    push @trade_dates, $date;
                }
                $forward_starting_options = [
                    map { {
                            date  => Date::Utility->new($_->{open})->truncate_to_day->epoch,
                            open  => $_->{open},
                            close => $_->{close},
                            @blackout_periods ? (blackouts => \@blackout_periods) : ()}
                        }
                        map {
                        @{$calendar->trading_period($exchange, $_)}
                        } @trade_dates
                ];
                $o->{forward_starting_options} = $forward_starting_options;
            }
        }

        # This key is being used to decide whether to show additional
        # barrier field on the frontend.
        if ($contract_category =~ /^(?:staysinout|endsinout|callputspread)$/) {
            $o->{barriers} = 2;
        } elsif ($contract_category eq 'lookback'
            or $contract_category eq 'asian'
            or $contract_category eq 'highlowticks'
            or $barrier_category eq 'euro_atm'
            or $contract_type =~ /^DIGIT(?:EVEN|ODD)$/)
        {
            $o->{barriers} = 0;
        } else {
            $o->{barriers} = 1;
        }

        # The reason why we have to append 't' to tick expiry duration
        # is because in the backend it is easier to handle them if the
        # min and max are set as numbers rather than strings.
        if ($o->{expiry_type} eq 'tick') {
            $o->{max_contract_duration} .= 't';
            $o->{min_contract_duration} .= 't';
        }

        next unless $o->{barriers};

        if ($barrier_category eq 'non_financial') {
            if ($contract_type =~ /^DIGIT(?:MATCH|DIFF)$/) {
                $o->{last_digit_range} = [0 .. 9];
            } elsif ($contract_type eq 'DIGITOVER') {
                $o->{last_digit_range} = [0 .. 8];
            } elsif ($contract_type eq 'DIGITUNDER') {
                $o->{last_digit_range} = [1 .. 9];
            }
        } else {
            if ($o->{barriers} == 1) {
                $o->{barrier} = _default_barrier({
                    underlying   => $underlying,
                    duration     => $o->{min_contract_duration},
                    barrier_kind => 'high'
                });
            } else {
                $o->{high_barrier} = _default_barrier({
                    underlying   => $underlying,
                    duration     => $o->{min_contract_duration},
                    barrier_kind => 'high'
                });
                $o->{low_barrier} = _default_barrier({
                    underlying   => $underlying,
                    duration     => $o->{min_contract_duration},
                    barrier_kind => 'low'
                });
            }
        }
    }

    return $offerings;
}

sub _default_barrier {
    my $args = shift;

    my ($underlying, $duration, $barrier_kind) = @{$args}{'underlying', 'duration', 'barrier_kind'};
    my $option_type = $barrier_kind eq 'low' ? 'VANILLA_PUT' : 'VANILLA_CALL';
    $duration =~ s/t//g;
    $duration = Time::Duration::Concise->new(interval => $duration)->seconds;

    my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying});
    # latest available spot should be sufficient.
    my $current_tick = defined $underlying->spot_tick ? $underlying->spot_tick : $underlying->tick_at(time, {allow_inconsistent => 1});
    return unless $current_tick;

    # volatility should just be an estimate here, let's take it straight off the surface and
    # avoid all the craziness.
    my $tid          = $duration / 86400;
    my $closest_term = find_closest_numbers_around($tid, $volsurface->original_term_for_smile, 2);
    my $volatility   = $volsurface->get_surface_volatility($closest_term->[0], $volsurface->atm_spread_point);

    my $approximate_barrier = get_strike_for_spot_delta({
        delta            => 0.2,
        option_type      => $option_type,
        atm_vol          => $volatility,
        t                => $tid / 365,
        r_rate           => 0,
        q_rate           => 0,
        spot             => $current_tick->quote,
        premium_adjusted => 0,
    });

    my $strike = BOM::Product::Contract::Strike->new(
        underlying       => $underlying,
        basis_tick       => $current_tick,
        supplied_barrier => $approximate_barrier,
        barrier_kind     => $barrier_kind,
    );

    my $barrier = $duration >= 86400 ? $strike->as_absolute : $strike->as_difference;

    return $underlying->market->integer_barrier ? floor($barrier) : $barrier;
}

1;
