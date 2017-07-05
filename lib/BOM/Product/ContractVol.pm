package BOM::Product::Contract;    ## no critic ( RequireFilenameMatchesPackage )

use strict;
use warnings;

use List::Util qw(sum);
use List::MoreUtils qw(none all);
use VolSurface::IntradayFX;
use BOM::Market::DataDecimate;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Product::Static;
use Quant::Framework::VolSurface;
use Quant::Framework::VolSurface::Utils qw(effective_date_for);
use Volatility::Seasonality;

## ATTRIBUTES  #######################

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

has economic_events_for_volatility_calculation => (
    is         => 'ro',
    lazy_build => 1,
);

has [qw(pricing_vol vol_at_strike)] => (
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

sub _calculate_historical_volatility {
    my ($self, $start, $end, $flag) = @_;

    my $hist_ticks = BOM::Market::DataDecimate->new->get({
        underlying => $self->underlying,
        # we use 20-minute fixed period and not more so that we capture the short-term volatility movement.
        start_epoch => $start->epoch,
        end_epoch   => $end->epoch,
    });

    my @returns_squared;
    # Ticks are in 15-second interval.
    my $returns_sep = 4;
    for (my $i = $returns_sep; $i <= $#$hist_ticks; $i++) {
        my $dt = $hist_ticks->[$i]->{epoch} - $hist_ticks->[$i - $returns_sep]->{epoch};
        next if $dt <= 0;
        # 252 is the number of trading days.
        push @returns_squared, ((log($hist_ticks->[$i]->{quote} / $hist_ticks->[$i - $returns_sep]->{quote})**2) * 252 * 86400 / $dt);
    }

    my $k = 1;
    if ($flag) {
        my $vs = Volatility::Seasonality->new(chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(1));
        my $sea_past = $vs->get_seasonality({
            underlying_symbol => $self->underlying->symbol,
            from              => $start,
            to                => $end
        });
        my $sea_fut = $vs->get_seasonality({
            underlying_symbol => $self->underlying->symbol,
            from              => $start,
            to                => $end
        });
        my $past_mean = sum(map { $_ * $_ } @$sea_past) / @$sea_past;
        my $fut_mean  = sum(map { $_ * $_ } @$sea_fut) / @$sea_fut;
        $k = $fut_mean / $past_mean;
    }

    unless (@returns_squared) {
        warn "Historical ticks not found in Intraday::Forex pricing";
        return 0.1;
    }

    return (sqrt(sum(@returns_squared) / @returns_squared)) * $k;
}

my $vol_weight_interpolator = Math::Function::Interpolator->new(
    points => {
        15  => 1,
        360 => 0
    });

sub weight_interpolator {
    my ($self, $min) = @_;
    return $vol_weight_interpolator->linear($min);
}

sub _weighted_vol {
    my $self = shift;

    my $vol;
    my $volatility_error;
    my $remaining_min = $self->remaining_time->minutes;

    if ($remaining_min <= 15) {
        $vol = $self->_calculate_historical_volatility($self->date_pricing->minus_time_interval('20m'), $self->date_pricing);
    } elsif ($remaining_min >= 6 * 60) {
        $vol = $self->intradayfx_volsurface->get_volatility({
            from                          => $self->effective_start->epoch,
            to                            => $self->date_expiry->epoch,
            include_economic_event_impact => 1,
        });
    } else {
        my $historical_vol_weight = $self->weight_interpolator($remaining_min);
        my $hist_vol              = $self->_calculate_historical_volatility($self->date_pricing->minus_time_interval('20m'), $self->date_pricing);
        my $market_vol            = $self->intradayfx_volsurface->get_volatility({
            from                          => $self->effective_start->epoch,
            to                            => $self->date_expiry->epoch,
            include_economic_event_impact => 1,
        });
        $vol = $historical_vol_weight * $hist_vol + (1 - $historical_vol_weight) * $market_vol;
    }
    return $vol;
}

sub _build_pricing_vol {
    my $self = shift;

    my $vol;
    my $volatility_error;
    if ($self->priced_with_intraday_model) {
        $vol = $self->_weighted_vol();
#        $vol = $self->intradayfx_volsurface->get_volatility({
#            from                          => $self->effective_start->epoch,
#            to                            => $self->date_expiry->epoch,
#            include_economic_event_impact => 1,
#        });
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
        # we might get an error while pricing contract, take care of them here.
        $volatility_error = $self->volsurface->validation_error if $self->volsurface->validation_error;
    }

    if ($volatility_error) {
        warn "Volatility error: $volatility_error";
        $self->_add_error({
            message           => $volatility_error,
            message_to_client => [$ERROR_MAPPING->{MissingVolatilityMarketData}],
        });
    }

    if ($vol <= 0) {
        $self->_add_error({
            message           => 'Zero volatility. Invalidate price.',
            message_to_client => [$ERROR_MAPPING->{CannotProcessContract}],
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

    return $self->_volsurface_fetcher->fetch_surface({
        underlying => $self->underlying,
    });
}

sub _build_intradayfx_volsurface {
    my $self = shift;
    return VolSurface::IntradayFX->new(
        underlying       => $self->underlying,
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader($self->underlying->for_date),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
        backprice        => ($self->underlying->for_date) ? 1 : 0,
    );
}

has [qw(long_term_prediction)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_long_term_prediction {
    my $self = shift;
    return $self->intradayfx_volsurface->long_term_prediction;
}

1;

