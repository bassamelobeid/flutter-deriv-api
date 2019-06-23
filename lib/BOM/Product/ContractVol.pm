package BOM::Product::Contract;    ## no critic ( RequireFilenameMatchesPackage )

use strict;
use warnings;

use List::MoreUtils qw(none all);
use List::Util qw(min max);
use Quant::Framework::VolSurface::Utils qw(effective_date_for);
use Quant::Framework::VolSurface;
use VolSurface::Empirical;
use Volatility::EconomicEvents;

use BOM::Market::DataDecimate;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Config::Chronicle;
use BOM::Product::Static;

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

sub _build_pricing_vol {
    my $self = shift;

    my $vol;
    my $volatility_error;

    if ($self->priced_with_intraday_model) {
        $vol = $self->empirical_volsurface->get_volatility({
            from  => $self->effective_start,
            to    => $self->date_expiry,
            delta => 50,
            ticks => $self->ticks_for_short_term_volatility_calculation,
        });
        $volatility_error = $self->empirical_volsurface->validation_error if $self->empirical_volsurface->validation_error;
    } else {
        if ($self->pricing_engine_name =~ /VannaVolga/) {
            $vol = $self->volsurface->get_volatility({
                delta => 50,
                from  => $self->effective_start->epoch,
                to    => $self->date_expiry->epoch,
            });
        } else {
            $vol = $self->vol_at_strike;
        }
        # we might get an error while pricing contract, take care of them here.
        $volatility_error = $self->volsurface->validation_error if $self->volsurface->validation_error;
    }

    if ($volatility_error) {
        $self->_add_error({
            message           => $volatility_error,
            message_to_client => [$ERROR_MAPPING->{MissingVolatilityMarketData}],
            details           => {field => 'symbol'},
        });
    }

    if ($vol <= 0) {
        $self->_add_error({
            message           => 'Zero or negative volatility. Invalidate price.',
            message_to_client => [$ERROR_MAPPING->{InvalidVolatility}],
            details           => {},
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

    return [grep { $_->{release_date} >= $start and $_->{release_date} <= $end } @$all_events];
}

sub _build_pricing_vol_for_two_barriers {
    my $self = shift;

    return if not $self->two_barriers;
    return if $self->pricing_engine_name ne 'Pricing::Engine::EuropeanDigitalSlope';

    my $vol_args = {
        from => $self->effective_start,
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

has empirical_volsurface => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_empirical_volsurface {
    my $self = shift;

    return VolSurface::Empirical->new(
        underlying       => $self->underlying,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader($self->underlying->for_date),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
    );
}

# should be removed once we verified that intraday vega correction is not useful
# in our intraday FX pricing model.
#
# These are kept as attributes so they can be over-written.
has [qw(long_term_prediction)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_long_term_prediction {
    my $self = shift;

    # long_term_prediction is set in VolSurface::Empirical. For contracts with duration less than 15 minutes,
    # we are only use historical volatility model hence taking a 10% volatility for it.
    return $self->empirical_volsurface->long_term_prediction // 0.1;
}

sub ticks_for_short_term_volatility_calculation {
    my $self = shift;
    return $self->_get_ticks_for_volatility_calculation({
        from => $self->effective_start->minus_time_interval('30m'),
        to   => $self->effective_start,
    });
}

sub _get_ticks_for_volatility_calculation {
    my ($self, $period) = @_;

    my $decimate = BOM::Market::DataDecimate->new({market => $self->market->name});
    my @ticks =
        map {
        $decimate->get({
                underlying  => $self->underlying,
                start_epoch => $_->[0],
                end_epoch   => $_->[1],
                backprice   => $self->underlying->for_date,
            })
        } @{$self->_get_tick_windows($period)};

    return \@ticks;
}

# We need a minimum number of ticks to calculate volatility. But these ticks cannot be influenced by econonic events
# since we are handling economic events impact separately.
#
# This method get ticks windows that are not affected by economic events by skipping them. First it looks back for 2 hours
# the get the events that could potentially impact volatility calculation. Then it combines overlapping events for
# smoother processing. Finally, it get the windows of ticks not affected by economic events.

sub _get_tick_windows {
    my ($self, $period) = @_;

    my $from = $period->{from}->epoch;
    my $to   = $period->{to}->epoch;
    my $diff = $to - $from;

    # just take events from two hour back and sort it in descending order
    my $categorized_events = [
        sort { $b->{release_date} <=> $a->{release_date} }
        grep { $_->{release_date} > $to - 2 * 3600 && $_->{release_date} < $to } @{$self->_applicable_economic_events}];

    return [[$from, $to]] unless @$categorized_events;

    # combine overlapping events
    my @combined;
    foreach my $event (@$categorized_events) {
        my $start_period = $event->{release_date};
        my $end_period   = $start_period + min(900, $event->{duration});
        my $curr         = [$start_period, $end_period];

        if (not @combined) {
            push @combined, $curr;
        } elsif ($curr->[0] == $combined[-1][0]) {
            $combined[-1][1] = max($curr->[1], $combined[-1][1]);    # overlapping release date, just take the maximum duration impact;
        } elsif ($curr->[1] >= $combined[-1][0]) {
            $combined[-1][0] = $curr->[0] if $curr->[0] < $combined[-1][0];
            $combined[-1][1] = $curr->[1] if $curr->[1] > $combined[-1][1];    # duration of current event spans across previously added event
        } else {
            push @combined, $curr;
        }
    }

    my @tick_windows;

    if ($combined[0][1] < $from) {
        push @tick_windows, [$from, $to];
    } else {
        my $end_of_period = $to;
        my $seconds_left  = $diff;
        foreach my $period (@combined) {
            if (@combined == 1 and $period->[1] >= $end_of_period) {
                push @tick_windows, [$period->[0] - $seconds_left, $period->[0]];
                $seconds_left = 0;
            } else {
                # use of min($to, x) is to avoid inverted start and end of period when
                # the event started before $to and ended after $to.
                my $start_of_period = min($to, max($period->[1], $end_of_period - $seconds_left));
                push @tick_windows, [$start_of_period, $end_of_period] if $start_of_period < $end_of_period;
                $seconds_left -= ($end_of_period - $start_of_period);
                last if $seconds_left <= 0;
                $end_of_period = $period->[0];
            }
        }

        # if we don't have 20 minutes worth of ticks after looping through the events,
        # add it here.
        if ($seconds_left > 0) {
            push @tick_windows, [$end_of_period - $seconds_left, $end_of_period];
        }
    }

    return \@tick_windows;
}

1;

