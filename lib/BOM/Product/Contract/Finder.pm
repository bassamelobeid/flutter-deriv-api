## no critic (ValuesAndExpressions::ProhibitCommaSeparatedStatements)

package BOM::Product::Contract::Finder;

use strict;
use warnings;

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
    my $symbol = shift || die 'no symbol';

    my $now        = Date::Utility->new;
    my $underlying = BOM::Market::Underlying->new($symbol);
    my $exchange   = $underlying->exchange;
    my $open       = $exchange->opening_on($now)->epoch;
    my $close      = $exchange->closing_on($now)->epoch;

    my $flyby = BOM::Product::Offerings::get_offerings_flyby;
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

            my %args = (
                underlying => $underlying,
                duration   => $o->{min_contract_duration});

            if ($o->{barriers} == 1) {
                $o->{barrier} = _default_barrier({%args, barrier_type => 'high'});
            }

            if ($o->{barriers} == 2) {
                $o->{high_barrier} = _default_barrier({%args, barrier_type => 'high'});
                $o->{low_barrier}  = _default_barrier({%args, barrier_type => 'low'});
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

sub _default_barrier {
    my $args = shift;

    my ($underlying, $duration, $barrier_type) = @{$args}{'underlying', 'duration', 'barrier_type'};
    my $option_type = 'VANILLA_CALL';
    $option_type = 'VANILLA_PUT' if $barrier_type eq 'low';

    $duration = Time::Duration::Concise->new(interval => $duration)->seconds;

    my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying});
    # latest available spot should be sufficient.
    my $barrier_spot        = defined $underlying->spot_tick ? $underlying->spot_tick : $underlying->tick_at(time, {allow_inconsistent => 1});
    my $tid                 = $duration / 86400;
    my $tiy                 = $tid / 365;
    my $approximate_barrier = get_strike_for_spot_delta({
            delta       => 0.2,
            option_type => $option_type,
            atm_vol     => $volsurface->get_volatility({
                    delta => 50,
                    days  => $tid
                }
            ),
            t                => $tiy,
            r_rate           => 0,
            q_rate           => 0,
            spot             => $barrier_spot->quote,
            premium_adjusted => 0,
        });

    my $strike = BOM::Product::Contract::Strike->new(
        underlying       => $underlying,
        basis_tick       => $barrier_spot,
        supplied_barrier => $approximate_barrier,
    );

    return $duration > 86400 ? $strike->as_absolute : $strike->as_relative;
}

1;
