package BOM::Product::Contract::Finder;

use strict;
use warnings;
use Date::Utility;
use Time::Duration::Concise;
use VolSurface::Utils qw(get_strike_for_spot_delta);
use BOM::Market::Underlying;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Product::Contract::Category;
use BOM::Product::Contract::Strike;
use BOM::Product::Offerings;
use base qw( Exporter );
our @EXPORT_OK = qw(available_contracts_for_symbol get_barrier);

sub available_contracts_for_symbol {
    my $args         = shift;
    my $symbol       = $args->{symbol} || die 'no symbol';
    my $underlying   = BOM::Market::Underlying->new($symbol);
    my $now          = Date::Utility->new;
    my $current_tick = $args->{current_tick} // $underlying->spot_tick // $underlying->tick_at($now->epoch, {allow_inconsistent => 1});

    my $exchange  = $underlying->exchange;
    my $open      = $exchange->opening_on($now)->epoch;
    my $close     = $exchange->closing_on($now)->epoch;
    my $flyby     = BOM::Product::Offerings::get_offerings_flyby;
    my @offerings = $flyby->query({underlying_symbol => $symbol});

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
            : $cc eq 'spreads'      ? 0
            : $cc eq 'digits'       ? 1
            : $cc eq 'touchnotouch' ? 1
            : $cc eq 'callput'      ? (
              $bc eq 'euro_atm'     ? 0
            : $bc eq 'euro_non_atm' ? 1
            :                         die "don't know about callput / $bc combo"
            )
            : die "don't know about contract category $cc";

        if ($o->{barriers}) {
            my $min_duration = Time::Duration::Concise->new(interval => $o->{min_contract_duration})->seconds;
            my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying});
            my $atm_vol = $volsurface->get_volatility({
                delta => 50,
                days  => $min_duration / 86400,
            });

            if ($o->{barriers} == 1) {
                $o->{barrier} = get_barrier({
                    underlying    => $underlying,
                    duration      => $min_duration,
                    direction     => 'high',
                    barrier_delta => 0.2,
                    barrier_tick  => $current_tick,
                    atm_vol       => $atm_vol
                });
            }

            if ($o->{barriers} == 2) {
                $o->{high_barrier} = get_barrier({
                    underlying    => $underlying,
                    duration      => $min_duration,
                    direction     => 'high',
                    barrier_delta => 0.2,
                    barrier_tick  => $current_tick,
                    atm_vol       => $atm_vol
                });
                $o->{low_barrier} = get_barrier({
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
    return {
        available => \@offerings,
        hit_count => scalar(@offerings),
        open      => $open,
        close     => $close,
    };
}

sub get_barrier {
    my $args = shift;

    my ($underlying, $duration, $direction, $barrier_delta, $barrier_tick, $absolute_barrier, $atm_vol) =
        @{$args}{'underlying', 'duration', 'direction', 'barrier_delta', 'barrier_tick', 'absolute_barrier', 'atm_vol'};

    my $approximate_barrier = get_strike_for_spot_delta({
        option_type => ($direction eq 'low') ? 'VANILLA_PUT' : 'VANILLA_CALL',
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
1;
