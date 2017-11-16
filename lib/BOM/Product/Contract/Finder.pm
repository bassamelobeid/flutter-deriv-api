package BOM::Product::Contract::Finder;

use strict;
use warnings;

use Date::Utility;
use POSIX qw(floor);
use Time::Duration::Concise;
use List::Util qw(first);
use VolSurface::Utils qw(get_strike_for_spot_delta);
use Cache::LRU;

use Quant::Framework;
use BOM::Platform::Chronicle;
use Finance::Contract::Category;
use LandingCompany::Offerings qw(get_offerings_flyby);

use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Product::Contract::Strike;

use base qw( Exporter );
our @EXPORT_OK = qw(available_contracts_for_symbol);

my %supported_contract_types = (
    ASIANU      => 1,
    ASIAND      => 1,
    CALL        => 1,
    CALLE       => 1,
    PUT         => 1,
    PUTE        => 1,
    DIGITDIFF   => 1,
    DIGITMATCH  => 1,
    DIGITOVER   => 1,
    DIGITUNDER  => 1,
    DIGITEVEN   => 1,
    DIGITODD    => 1,
    EXPIRYMISS  => 1,
    EXPIRYRANGE => 1,
    RANGE       => 1,
    UPORDOWN    => 1,
    ONETOUCH    => 1,
    NOTOUCH     => 1,
);

my $cache = Cache::LRU->new(
    size => 1000,
);

sub _get_cached_or_calculate {
    my $k = shift;
    $k = join '_', ($ENV{ITERATION_STARTED} // time), @$k;
    my $r;
    return $r if $r = $cache->get($k);
    $cache->set($k => shift->());
    return $cache->get($k);
}

sub _forward_starting_options {
    my ($underlying, $calendar, $exchange) = @_;
    my $now = Date::Utility->new;
    my $sod = $now->truncate_to_day->epoch;
    my @blackout_periods;
    if (my @inefficient_periods = @{$underlying->forward_inefficient_periods}) {
        push @blackout_periods, [Date::Utility->new($sod + $_->{start})->time_hhmmss, Date::Utility->new($sod + $_->{end})->time_hhmmss]
            for @inefficient_periods;
    }
    my @trade_dates;
    for (my $date = $now; @trade_dates < 3; $date = $date->plus_time_interval('1d')) {
        $date = $calendar->trade_date_after($exchange, $date) unless $calendar->trades_on($exchange, $date);
        push @trade_dates, $date;
    }

    my $v = [
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
    return $v;
}

sub available_contracts_for_symbol {
    my $args            = shift;
    my $symbol          = $args->{symbol} || die 'no symbol';
    my $landing_company = $args->{landing_company};

    my $now        = Date::Utility->new;
    my $underlying = _get_cached_or_calculate([$symbol], sub { create_underlying($symbol) });
    my $exchange   = $underlying->exchange;

    my ($calendar, $open, $close) = @{
        _get_cached_or_calculate(
            [$underlying->exchange],
            sub {
                my $calendar = Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader());
                my ($open, $close);
                if ($calendar->trades_on($underlying->exchange, $now)) {
                    $open = $calendar->opening_on($exchange, $now)->epoch;
                    $close = $calendar->closing_on($exchange, $now)->epoch;
                }
                [$calendar, $open, $close];
            })};

    my $flyby = _get_cached_or_calculate(['flyby', $landing_company // ''],
        sub { get_offerings_flyby(BOM::Platform::Runtime->instance->get_offerings_config, $landing_company) });
    my @offerings = grep { $supported_contract_types{$_->{contract_type}} } $flyby->query({underlying_symbol => $symbol});

    for my $o (@offerings) {
        my $cc = $o->{contract_category};
        my $bc = $o->{barrier_category};

        my $cat = _get_cached_or_calculate(['category', $cc], sub { Finance::Contract::Category->new($cc) });
        $o->{contract_category_display} = $cat->display_name;
        $o->{contract_display}          = $o->{contract_display};

        if ($o->{start_type} eq 'forward') {
            $o->{forward_starting_options} =
                _get_cached_or_calculate(['forward_starting_options', $symbol], sub { _forward_starting_options($underlying, $calendar, $exchange) });
        }

        # This key is being used to decide whether to show additional
        # barrier field on the frontend.
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

        if ($o->{barriers} and $o->{barrier_category} ne 'non_financial') {
            if ($o->{barriers} == 1) {
                $o->{barrier} = _default_barrier({
                    underlying   => $underlying,
                    duration     => $o->{min_contract_duration},
                    barrier_type => 'high'
                });
            }

            if ($o->{barriers} == 2) {
                $o->{high_barrier} = _default_barrier({
                    underlying   => $underlying,
                    duration     => $o->{min_contract_duration},
                    barrier_type => 'high'
                });
                $o->{low_barrier} = _default_barrier({
                    underlying   => $underlying,
                    duration     => $o->{min_contract_duration},
                    barrier_type => 'low'
                });
            }
        }

        # The reason why we have to append 't' to tick expiry duration
        # is because in the backend it is easier to handle them if the
        # min and max are set as numbers rather than strings.
        if ($o->{expiry_type} eq 'tick') {
            $o->{max_contract_duration} .= 't';
            $o->{min_contract_duration} .= 't';
        }

        # digits has a non_financial barrier which is between 0 to 9
        if ($cc eq 'digits') {
            if (first { $o->{contract_type} eq $_ } qw(DIGITEVEN DIGITODD)) {
                $o->{barriers} = 0;    # override barriers here.
            } else {
                if (first { $o->{contract_type} eq $_ } qw(DIGITMATCH DIGITDIFF)) {
                    $o->{last_digit_range} = [0 .. 9];
                } elsif ($o->{contract_type} eq 'DIGITOVER') {
                    $o->{last_digit_range} = [0 .. 8];
                } elsif ($o->{contract_type} eq 'DIGITUNDER') {
                    $o->{last_digit_range} = [1 .. 9];
                }
            }
        }
    }

    return {
        available    => \@offerings,
        hit_count    => scalar(@offerings),
        open         => $open,
        close        => $close,
        feed_license => $underlying->feed_license,
        @offerings ? (spot => _get_cached_or_calculate([$symbol, 'spot'], sub { $underlying->spot })) : (),
    };
}

sub _default_barrier {
    my $args = shift;

    my ($underlying, $duration, $barrier_type) = @{$args}{'underlying', 'duration', 'barrier_type'};

    return _get_cached_or_calculate([$underlying->system_symbol, $duration, $barrier_type],
        sub { _default_barrier_calc($underlying, $duration, $barrier_type) });

}

sub _default_barrier_calc {

    my ($underlying, $duration, $barrier_type) = @_;
    my $option_type = 'VANILLA_CALL';
    $option_type = 'VANILLA_PUT' if $barrier_type eq 'low';

    $duration = Time::Duration::Concise->new(interval => $duration)->seconds;

    my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying});
    # latest available spot should be sufficient.
    my $barrier_spot = defined $underlying->spot_tick ? $underlying->spot_tick : $underlying->tick_at(time, {allow_inconsistent => 1});
    return unless $barrier_spot;
    my $tid        = $duration / 86400;
    my $tiy        = $tid / 365;
    my $now        = Date::Utility->new;
    my $volatility = $volsurface->get_volatility({
        $volsurface->type => $volsurface->atm_spread_point,
        from              => $now,
        to                => $now->plus_time_interval($duration),
    });
    my $approximate_barrier = get_strike_for_spot_delta({
        delta            => 0.2,
        option_type      => $option_type,
        atm_vol          => $volatility,
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

    my $barrier = $duration >= 86400 ? $strike->as_absolute : $strike->as_difference;

    return $underlying->market->integer_barrier ? floor($barrier) : $barrier;
}

1;
