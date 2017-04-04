package BOM::Product::Contract;    ## no critic ( RequireFilenameMatchesPackage )

use strict;
use warnings;

## ATTRIBUTES  #######################

use BOM::MarketData::Fetcher::VolSurface;
use List::MoreUtils qw(none all);
use BOM::Market::DataDecimate;
use VolSurface::IntradayFX;
use Quant::Framework::VolSurface;
use BOM::Platform::Context qw(localize);

## ATTRIBUTES  #######################

has economic_events_for_volatility_calculation => (
    is         => 'ro',
    lazy_build => 1,
);

has [qw(pricing_vol vol_at_strike news_adjusted_pricing_vol)] => (
    is         => 'ro',
    isa        => 'Maybe[Num]',
    lazy_build => 1,
);

has pricing_vol_for_two_barriers => (
    is         => 'ro',
    isa        => 'Maybe[HashRef]',
    lazy_build => 1,
);

has atm_vols => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1
);

has intradayfx_volsurface => (
    is         => 'ro',
    isa        => 'Maybe[VolSurface::IntradayFX]',
    lazy_build => 1,
);

has volsurface => (
    is         => 'rw',
    isa        => 'Quant::Framework::VolSurface',
    lazy_build => 1,
);

has vol_at_strike => (
    is         => 'rw',
    isa        => 'Maybe[PositiveNum]',
    lazy_build => 1,
);

has _volsurface_fetcher => (
    is         => 'ro',
    isa        => 'BOM::MarketData::Fetcher::VolSurface',
    init_arg   => undef,
    lazy_build => 1,
);

#== METHODS ===================

sub _vols_at_point {
    my ($self, $end_date, $days_attr) = @_;

    my $vol_args = {
        delta => 50,
        from  => $self->effective_start,
        to    => $self->date_expiry,
    };

    my $market_name = $self->underlying->market->name;
    my %vols_to_use;
    foreach my $pair (qw(fordom domqqq forqqq)) {
        my $pair_ref = $self->$pair;
        $pair_ref->{volsurface} //= $self->_volsurface_fetcher->fetch_surface({
            underlying => $pair_ref->{underlying},
        });
        $pair_ref->{vol} //= $pair_ref->{volsurface}->get_volatility($vol_args);
        $vols_to_use{$pair} = $pair_ref->{vol};
    }

    if (none { $market_name eq $_ } (qw(forex commodities indices))) {
        $vols_to_use{domqqq} = $vols_to_use{fordom};
        $vols_to_use{forqqq} = $vols_to_use{domqqq};
    }

    return \%vols_to_use;
}

### BUILDERS #########################

sub _build_atm_vols {
    my $self = shift;

    return $self->_vols_at_point($self->date_expiry, 'timeindays');
}

sub _build_vol_at_strike {
    my $self = shift;

    #If surface is flat, don't bother calculating all those arguments
    return $self->volsurface->get_volatility if ($self->underlying->volatility_surface_type eq 'flat');

    my $pricing_spot = $self->pricing_spot;
    my $vol_args     = {
        strike => $self->barriers_for_pricing->{barrier1},
        q_rate => $self->q_rate,
        r_rate => $self->r_rate,
        spot   => $pricing_spot,
        from   => $self->effective_start,
        to     => $self->date_expiry,
    };

    if ($self->two_barriers) {
        $vol_args->{strike} = $pricing_spot;
    }

    return $self->volsurface->get_volatility($vol_args);
}

sub _build_news_adjusted_pricing_vol {
    my $self            = shift;
    my $effective_start = $self->effective_start;

    return $self->intradayfx_volsurface->get_volatility({
        from                          => $effective_start->epoch,
        to                            => $self->date_expiry->epoch,
        include_economic_event_impact => 1,
    });
}

sub _build_pricing_vol {
    my $self = shift;

    my $vol;
    my $volatility_error;
    if ($self->priced_with_intraday_model) {
        my $volsurface       = $self->intradayfx_volsurface;
        my $duration_seconds = $self->timeindays->amount * 86400;
        # volatility doesn't matter for less than 10 minutes ATM contracts,
        # where the intraday_delta_correction is the bounceback which is a function of trend, not volatility.
        my $uses_flat_vol = ($self->is_atm_bet and $duration_seconds < 10 * 60) ? 1 : 0;
        if ($uses_flat_vol) {
            $vol = $volsurface->long_term_volatility({
                from => $self->effective_start->epoch,
            });
        } else {
            $vol = $volsurface->get_volatility({
                from                          => $self->effective_start->epoch,
                to                            => $self->date_expiry->epoch,
                include_economic_event_impact => 0,
            });
        }
        unless($vol) {
            warn "falt_vol: $uses_flat_vol";
    }
    } else {
        if ($self->pricing_engine_name =~ /VannaVolga/) {
            $vol = $self->volsurface->get_volatility({
                from  => $self->effective_start,
                to    => $self->date_expiry,
                delta => 50
            });
        } else {
            $vol = $self->vol_at_strike;
        }
        unless($vol) {
            warn "VV";
        }
        # we might get an error while pricing contract, take care of them here.
        $volatility_error = $self->volsurface->validation_error if $self->volsurface->validation_error;
    }

    if ($volatility_error) {
        warn "Volatility error: $volatility_error";
        $self->add_error({
            message           => $volatility_error,
            message_to_client => localize('Trading on this market is suspended due to missing market (volatility) data.'),
        });
    }

    unless($vol) {
          use Devel::StackTrace;

            my $trace = Devel::StackTrace->new;

              warn $trace->as_string;
    }

    if ($vol <= 0) {
        $self->add_error({
            message           => 'Zero volatility. Invalidate price.',
            message_to_client => localize('We could not process this contract at this time.'),
        });
    }

    return $vol;
}

sub _build_economic_events_for_volatility_calculation {
    my $self = shift;

    my $all_events        = $self->_applicable_economic_events;
    my $effective_start   = $self->effective_start;
    my $seconds_to_expiry = $self->get_time_to_expiry({from => $effective_start})->seconds;
    my $current_epoch     = $effective_start->epoch;
    # Go back another hour because we expect the maximum impact on any news would not last for more than an hour.
    my $start = $current_epoch - $seconds_to_expiry - 3600;
    # Plus 5 minutes for the shifting logic.
    # If news occurs 5 minutes before/after the contract expiration time, we shift the news triangle to 5 minutes before the contract expiry.
    my $end = $current_epoch + $seconds_to_expiry + 300;

    return [grep { $_->{release_date} >= $start and $_->{release_date} <= $end and $_->{impact} > 1 } @$all_events];
}

sub _build_pricing_vol_for_two_barriers {
    my $self = shift;

    return if not $self->two_barriers;
    return if $self->pricing_engine_name ne 'Pricing::Engine::EuropeanDigitalSlope';

    my $vol_args = {
        from => $self->date_start,
        to   => $self->date_expiry,
    };

    $vol_args->{strike} = $self->barriers_for_pricing->{barrier1};
    my $high_barrier_vol = $self->volsurface->get_volatility($vol_args);

    $vol_args->{strike} = $self->barriers_for_pricing->{barrier2};
    my $low_barrier_vol = $self->volsurface->get_volatility($vol_args);

    return {
        high_barrier_vol => $high_barrier_vol,
        low_barrier_vol  => $low_barrier_vol
    };
}

sub _build__volsurface_fetcher {
    return BOM::MarketData::Fetcher::VolSurface->new;
}

sub _build_volsurface {
    my $self = shift;

    # Due to the craziness we have in volsurface cutoff. This complexity is needed!
    # FX volsurface has cutoffs at either 21:00 or 23:59 or the early close time.
    # Index volsurfaces shouldn't have cutoff concept. But due to the system design, an index surface cuts at the close of trading time on a non-DST day.
    my %submarkets = (
        major_pairs => 1,
        minor_pairs => 1
    );
    my $vol_utils = Quant::Framework::VolSurface::Utils->new;
    my $cutoff_str;
    if ($submarkets{$self->underlying->submarket->name}) {
        my $calendar       = $self->calendar;
        my $effective_date = $vol_utils->effective_date_for($self->date_pricing);
        $effective_date = $calendar->trades_on($effective_date) ? $effective_date : $calendar->trade_date_after($effective_date);
        my $cutoff_date = $calendar->closing_on($effective_date);

        $cutoff_str = $cutoff_date->time_cutoff;
    }

    return $self->_volsurface_fetcher->fetch_surface({
        underlying => $self->underlying,
        (defined $cutoff_str) ? (cutoff => $cutoff_str) : (),
    });
}

sub _build_intradayfx_volsurface {
    my $self = shift;
    return VolSurface::IntradayFX->new(
        underlying       => $self->underlying,
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader($self->underlying->for_date),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
    );
}

has ticks_for_volatility_calculation => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_ticks_for_volatility_calculation {
    my $self = shift;

    # Minimum ticks interval to calculate volatility.
    # If we price a contract with duration less that 15 minutes, we will still use a 15-minute period of ticks to calculate its volatility
    my $minimum_interval = 900;
    my $interval = Time::Duration::Concise->new(interval => max(900, $self->date_expiry->epoch - $self->effective_start->epoch) . 's');
    # to avoid race condition in spot for volatility calculation, we request for ticks one second before the contract pricing time.
    my $volatility_request_time = $self->effective_start->minus_time_interval('1s');

    my $backprice = ($self->underlying->for_date) ? 1 : 0;

    my $ticks = BOM::Market::DataDecimate->new()->decimate_cache_get({
        underlying  => $self->underlying,
        start_epoch => $volatility_request_time->epoch - $interval->seconds,
        end_epoch   => $volatility_request_time->epoch,
        backprice   => $backprice,
    });

    return $ticks;
}
1;

