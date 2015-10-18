package BOM::Product::Pricing::Engine::Slope;

use 5.010;
use Moose;

use Storable qw(dclone);
use List::Util qw(min max sum);
use YAML::CacheLoader qw(LoadFile);
use Finance::Asset;
use Math::Function::Interpolator;
use Math::Business::BlackScholes::Binaries;
use Math::Business::BlackScholes::Binaries::Greeks::Vega;
use Math::Business::BlackScholes::Binaries::Greeks::Delta;

has [
    qw(contract_type spot strikes date_start date_pricing date_expiry discount_rate mu vol payouttime_code q_rate r_rate priced_with underlying_symbol)
    ] => (
    is       => 'ro',
    required => 1,
    );

# required for now since market data and convention are still
# very much intact to BOM code
has [qw(market_data market_convention)] => (
    is       => 'ro',
    required => 1,
);

has debug_information => (
    is      => 'rw',
    default => sub { {} },
);

has error => (
    is       => 'rw',
    init_arg => undef,
    default  => '',
);

has supported_contract_types => (
    is      => 'ro',
    default => sub {
        return {
            CALL        => 1,
            PUT         => 1,
            EXPIRYMISS  => 1,
            EXPIRYRANGE => 1
        };
    },
);

sub BUILD {
    my $self = shift;

    my $contract_type = $self->contract_type;
    unless ($self->supported_contract_types->{$contract_type}) {
        $self->error('Unsupported contract type [' . $contract_type . '] for ' . __PACKAGE__);
    }

    my @strikes = @{$self->strikes};
    my $err     = 'Barrier error for contract type [' . $contract_type . ']';
    if ($self->_two_barriers) {
        $self->error($err) if @strikes != 2;
    } else {
        $self->error($err) if @strikes != 1;
    }

    if ($self->date_expiry->is_before($self->date_start)) {
        $self->error('Date expiry is before date start');
    }

    return;
}

has underlying_config => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_underlying_config',
);

sub _build_underlying_config {
    my $self = shift;
    return Finance::Asset->instance->get_parameters_for($self->underlying_symbol);
}

has timeindays => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_timeindays',
);

sub _build_timeindays {
    my $self = shift;

    return max(1, $self->market_convention->{calculate_expiry}->($self->date_start, $self->date_expiry))
        if $self->underlying_config->{market} eq 'forex';
    return ($self->date_expiry->epoch - $self->date_start->epoch) / 86400;
}

has timeinyears => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_timeinyears',
);

sub _build_timeinyears {
    my $self = shift;
    return $self->timeindays / 365;
}

has is_forward_starting => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_is_forward_starting',
);

sub _build_is_forward_starting {
    my $self = shift;
    # 5 seconds is used as the threshold.
    # if pricing takes more than that, we are in trouble.
    return ($self->date_start->epoch - $self->date_pricing->epoch > 5) ? 1 : 0;
}

has _two_barriers => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_two_barriers',
);

sub _build_two_barriers {
    my $self = shift;
    return (grep { $self->contract_type eq $_ } qw(EXPIRYMISS EXPIRYRANGE)) ? 1 : 0;
}

has is_intraday => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_is_intraday',
);

sub _build_is_intraday {
    my $self = shift;
    return ($self->timeindays > 1) ? 0 : 1;
}

has is_atm_contract => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_is_atm_contract',
);

sub _build_is_atm_contract {
    my $self = shift;
    return ($self->_two_barriers or $self->spot != $self->strikes->[0]) ? 0 : 1;
}

has _formula_args => (
    is      => 'ro',
    default => sub { [qw(spot strikes timeinyears discount_rate mu vol payouttime_code)] },
);

sub required_args {
    return [
        qw(contract_type spot strikes date_start date_pricing date_expiry discount_rate mu vol payouttime_code q_rate r_rate priced_with underlying_symbol market_data market_convention)
    ];
}

sub bs_probability {
    my $self = shift;

    return 1 if $self->error;
    my $bs_formula = _bs_formula_for($self->contract_type);
    return $bs_formula->($self->_to_array($self->_pricing_args));
}

sub probability {
    my $self = shift;

    return 1 if $self->error;
    return $self->_calculate_probability;
}

sub risk_markup {
    my $self = shift;

    return 0 if $self->error;

    my $market        = $self->underlying_config->{market};
    my $markup_config = _markup_config($market);
    my $is_intraday   = $self->is_intraday;

    my $risk_markup = 0;
    if ($markup_config->{'traded_market_markup'}) {
        # risk_markup is zero for forward_starting contracts due to complaints from Australian affiliates.
        return $risk_markup if ($self->is_forward_starting);

        my %greek_params = %{$self->_pricing_args};
        $greek_params{vol} = $self->market_data->{get_atm_volatility}->($self->_get_vol_expiry);
        # vol_spread_markup
        my $spread_type = $self->is_atm_contract ? 'atm' : 'max';
        my $vol_spread = $self->market_data->{get_vol_spread}->($spread_type, $self->timeindays);
        my $bs_vega_formula   = _greek_formula_for('vega', $self->contract_type);
        my $bs_vega           = abs($bs_vega_formula->($self->_to_array(\%greek_params)));
        my $vol_spread_markup = max($vol_spread * $bs_vega, 0.07);
        $risk_markup += $vol_spread_markup;
        $self->debug_information->{risk_markup}{vol_spread_markup} = $vol_spread_markup;

        # spot_spread_markup
        if (not $is_intraday) {
            my $spot_spread_size   = $self->underlying_config->{spot_spread_size} // 50;
            my $spot_spread_base   = $spot_spread_size * $self->underlying_config->{pip_size};
            my $bs_delta_formula   = _greek_formula_for('delta', $self->contract_type);
            my $bs_delta           = abs($bs_delta_formula->($self->_to_array(\%greek_params)));
            my $spot_spread_markup = max($spot_spread_base * $bs_delta, 0.01);
            $risk_markup += $spot_spread_markup;
            $self->debug_information->{risk_markup}{spot_spread_markup} = $spot_spread_markup;
        }

        # economic_events_markup
        if ($markup_config->{'economic_event_markup'} and $is_intraday and $self->timeindays * 86400 > 10) {
            my $secs_to_expiry  = $self->timeindays * 86400;
            my $start           = $self->date_start->minus_time_interval('20m');
            my $end             = $self->date_expiry->plus_time_interval('10m');
            my @economic_events = $self->market_data->{get_economic_event}->($self->underlying_symbol, $start, $end);

            my $step_size = 100;
            my @triangle_sum = (0) x ($step_size + 1);
            foreach my $event (@economic_events) {
                my $release_date = $event->release_date;
                my $scale = $event->get_scaling_factor($self->underlying_symbol, 'spot');
                next if not defined $scale;
                my $x1                 = $release_date->epoch;
                my $x2                 = $release_date->plus_time_interval('20m')->epoch;
                my $y1                 = $scale;
                my $y2                 = 0;
                my $triangle_slope     = ($y1 - $y2) / ($x1 - $x2);
                my $intercept          = $y1 - $triangle_slope * $x1;
                my $epsilon            = $secs_to_expiry / $step_size;
                my $t                  = $self->date_start->epoch;
                my $primary_sum        = (3 / 4 * $scale * 600) / $epsilon;
                my $primary_sum_index  = 0;
                my $ten_minutes_after  = $release_date->plus_time_interval('10m');
                my $ten_minutes_before = $release_date->plus_time_interval('10m');

                my @triangle;
# for intervals between $bet->effective_start->epoch and $bet->date_expiry->epoch
                for (0 .. $step_size) {
                    my $height = 0;
                    $primary_sum_index++ if $t <= $x1;
                    if ($t >= $ten_minutes_after->epoch and $t <= $x2) {
                        $height = $triangle_slope * $t + $intercept;
                    }
                    push @triangle, $height;
                    $t += $epsilon;
                }

                if (    $self->date_start->epoch <= $ten_minutes_after->epoch
                    and $self->date_expiry->epoch >= $ten_minutes_before->epoch)
                {
                    $primary_sum_index = min($primary_sum_index, $#triangle);
                    $triangle[$primary_sum_index] = $primary_sum;
                }

                @triangle_sum = map { max($triangle_sum[$_], $triangle[$_]) } (0 .. $#triangle);
            }

            my $eco_events_spot_risk_markup = sum(@triangle_sum) / $step_size;
            $risk_markup += $eco_events_spot_risk_markup;
            $self->debug_information->{risk_markup}{economic_event_markup} = $eco_events_spot_risk_markup;
        }

        # end of day market risk markup
        # This is added for uncertainty in volatilities during rollover period.
        # The rollover time for volsurface is set at NY 1700. However, we are not sure when the actual rollover
        # will happen. Hence we add a 5% markup to the price.
        # if forex or commodities and duration <= 3
        if ($markup_config->{'end_of_day_markup'} and $self->timeindays <= 3) {
            my $ny_1600 = $self->market_convention->{get_rollover_time}->($self->date_start)->minus_time_interval('1h');
            if ($ny_1600->is_before($self->date_start) or ($is_intraday and $ny_1600->is_before($self->date_expiry))) {
                my $eod_market_risk_markup = 0.05;    # flat 5%
                $risk_markup += $eod_market_risk_markup;
                $self->debug_information->{risk_markup}{eod_market_risk_markup} = $eod_market_risk_markup;
            }
        }

        # This is added for the high butterfly condition where the butterfly is higher than threshold (0.01),
        # then we add the difference between then original probability and adjusted butterfly probability as markup.
        if ($markup_config->{'butterfly_markup'} and $self->timeindays == $self->market_data->{get_overnight_days}->()) {
            my $butterfly_cutoff = 0.01;
            my $original_surface = $self->market_data->{get_volsurface_data}->($self->underlying_symbol);
            my $first_term       = (sort { $a <=> $b } keys %$original_surface)[0];
            my $market_rr_bf     = $self->market_data->{get_market_rr_bf}->($first_term);
            if ($first_term == $self->market_data->{get_overnight_days}->() and $market_rr_bf->{BF_25} > $butterfly_cutoff) {
                my $original_bf = $market_rr_bf->{BF_25};
                my $original_rr = $market_rr_bf->{RR_25};
                my ($atm, $c25, $c75) = map { $original_surface->{$first_term}{smile}{$_} } qw(50 25 75);
                my $c25_mod             = $butterfly_cutoff + $atm + 0.5 * $original_rr;
                my $c75_mod             = $c25 - $original_rr;
                my $cloned_surface_data = dclone($original_surface);
                $cloned_surface_data->{$first_term}{smile}{25} = $c25_mod;
                $cloned_surface_data->{$first_term}{smile}{75} = $c75_mod;
                my $vol_args = {
                    strike => $self->_two_barriers ? $self->spot : $self->strikes->[0],
                    %{$self->_get_vol_expiry},
                };
                my $vol_after_butterfly_adjustment = $self->market_data->{get_volatility}->($vol_args, $cloned_surface_data);
                my $butterfly_adjusted_prob = $self->_calculate_probability({vol => $vol_after_butterfly_adjustment});
                my $butterfly_markup = abs($self->probability - $butterfly_adjusted_prob);
                $risk_markup += $butterfly_markup;
                $self->debug_information->{risk_markup}{butterfly_markup} = $butterfly_markup;
            }
        }

        # risk_markup divided equally on both sides.
        $risk_markup /= 2;
    }

    return $risk_markup;
}

sub commission_markup {
    my $self = shift;

    return 0    if $self->error;
    return 0.03 if $self->is_forward_starting;

    my $comm_file        = LoadFile('/home/git/regentmarkets/bom/lib/BOM/Product/Pricing/Engine/commission.yml');
    my $commission_level = $comm_file->{commission_level}->{$self->underlying_symbol};
    my $dsp_amount       = $comm_file->{digital_spread_base}->{$self->underlying_config->{market}}->{$self->contract_type} // 0;
    $dsp_amount /= 100;
    # this is added so that we match the commission of tick trades
    $dsp_amount /= 2 if $self->timeindays * 86400 <= 20 and $self->is_atm_contract;
    # 1.4 is the hard-coded level multiplier
    my $level_multiplier          = 1.4**($commission_level - 1);
    my $digital_spread_percentage = $dsp_amount * $level_multiplier;
    my $fixed_scaling             = $comm_file->{digital_scaling_factor}->{$self->underlying_symbol};
    my $dsp_interp                = Math::Function::Interpolator->new(
        points => {
            0   => 1.5,
            1   => 1.5,
            10  => 1.2,
            20  => 1,
            365 => 1,
        });
    my $dsp_scaling           = $fixed_scaling || $dsp_interp->linear($self->timeinyears);
    my $digital_spread_markup = $digital_spread_percentage * $dsp_scaling;
    my $commission_markup     = $digital_spread_markup / 2;

    return $commission_markup;
}

sub _calculate_probability {
    my ($self, $modified) = @_;

    my $contract_type = delete $modified->{contract_type} || $self->contract_type;

    my $probability;
    if ($contract_type eq 'EXPIRYMISS') {
        $probability = $self->_two_barrier_probability($modified);
    } elsif ($contract_type eq 'EXPIRYRANGE') {
        my $discounted_probability = exp(-$self->discount_rate * $self->timeinyears);
        $self->debug_information->{discounted_probability} = $discounted_probability;
        $probability = $discounted_probability - $self->_two_barrier_probability($modified);
    } else {
        my $priced_with = $self->priced_with;
        my $params      = $self->_pricing_args;
        $params->{$_} = $modified->{$_} foreach keys %$modified;

        my (%debug_information, $calc_parameters);
        if ($priced_with eq 'numeraire') {
            ($probability, $calc_parameters) = $self->_calculate($contract_type, $params);
            $debug_information{theo_probability}{amount}     = $probability;
            $debug_information{theo_probability}{parameters} = $calc_parameters;
        } elsif ($priced_with eq 'quanto') {
            $params->{mu} = $self->r_rate - $self->q_rate;
            ($probability, $calc_parameters) = $self->_calculate($contract_type, $params);
            $debug_information{theo_probability}{amount}     = $probability;
            $debug_information{theo_probability}{parameters} = $calc_parameters;
        } elsif ($priced_with eq 'base') {
            my %cloned_params = %$params;
            $cloned_params{mu}            = $self->r_rate - $self->q_rate;
            $cloned_params{discount_rate} = $self->r_rate;
            my $numeraire_prob;
            ($numeraire_prob, $calc_parameters) = $self->_calculate($contract_type, \%cloned_params);
            $debug_information{theo_probability}{parameters}{numeraire_probability}{amount}     = $numeraire_prob;
            $debug_information{theo_probability}{parameters}{numeraire_probability}{parameters} = $calc_parameters;
            my $vanilla_formula          = _bs_formula_for('vanilla_' . $contract_type);
            my $base_vanilla_probability = $vanilla_formula->($self->_to_array($params));
            $debug_information{theo_probability}{parameters}{base_vanilla_probability}{amount}     = $base_vanilla_probability;
            $debug_information{theo_probability}{parameters}{base_vanilla_probability}{parameters} = $params;
            my $which_way = $contract_type eq 'CALL' ? 1 : -1;
            my $strike = $params->{strikes}->[0];
            $debug_information{theo_probability}{parameters}{spot}{amount}   = $self->spot;
            $debug_information{theo_probability}{parameters}{strike}{amount} = $strike;
            $probability = ($numeraire_prob * $strike + $base_vanilla_probability * $which_way) / $self->spot;
            $debug_information{theo_probability}{amount} = $probability;
        } else {
            $self->error('Unrecognized priced_with[' . $priced_with . ']');
            $probability = 1;
        }

        $self->debug_information->{$contract_type} = \%debug_information;
    }

    return $probability;
}

sub _two_barrier_probability {
    my ($self, $modified) = @_;

    my ($low_strike, $high_strike) = sort { $a <=> $b } @{$self->strikes};

    my $vol_args = $self->_get_vol_expiry;
    $vol_args->{strike} = $high_strike;
    my $high_vol  = $self->market_data->{get_volatility}->($vol_args);
    my $call_prob = $self->_calculate_probability({
        contract_type => 'CALL',
        strikes       => [$high_strike],
        vol           => $high_vol,
        %$modified
    });

    $vol_args->{strike} = $low_strike;
    my $low_vol  = $self->market_data->{get_volatility}->($vol_args);
    my $put_prob = $self->_calculate_probability({
        contract_type => 'PUT',
        strikes       => [$low_strike],
        vol           => $low_vol,
        %$modified
    });

    return $call_prob + $put_prob;
}

sub _calculate {
    my ($self, $contract_type, $params) = @_;

    my %debug_information;
    my $bs_formula     = _bs_formula_for($contract_type);
    my @pricing_args   = $self->_to_array($params);
    my $bs_probability = $bs_formula->(@pricing_args);
    $debug_information{bs_probability}{amount}     = $bs_probability;
    $debug_information{bs_probability}{parameters} = $params;

    my $slope_adjustment = 0;
    unless ($self->is_forward_starting) {
        my $vanilla_vega_formula = _greek_formula_for('vega', 'vanilla_' . $contract_type);
        my $vanilla_vega = $vanilla_vega_formula->(@pricing_args);
        $debug_information{slope_adjustment}{parameters}{vanilla_vega}{amount}     = $vanilla_vega;
        $debug_information{slope_adjustment}{parameters}{vanilla_vega}{parameters} = $params;
        my $strike   = $params->{strikes}->[0];
        my $vol_args = {
            spot   => $self->spot,
            q_rate => $self->q_rate,
            r_rate => $self->r_rate,
            %{$self->_get_vol_expiry}};
        my $pip_size = $self->underlying_config->{pip_size};
        # Move by pip size either way.
        $vol_args->{strike} = $strike - $pip_size;
        my $down_vol = $self->market_data->{get_volatility}->($vol_args);
        $vol_args->{strike} = $strike + $pip_size;
        my $up_vol = $self->market_data->{get_volatility}->($vol_args);
        my $slope = ($up_vol - $down_vol) / (2 * $pip_size);
        $debug_information{slope_adjustment}{parameters}{slope} = $slope;
        my $base_amount = $contract_type eq 'CALL' ? -1 : 1;
        $slope_adjustment = $base_amount * $vanilla_vega * $slope;

        if ($self->_get_first_tenor_on_surface() > 7 and $self->is_intraday) {
            $slope_adjustment = max(-0.03, min(0.03, $slope_adjustment));
        }
        $debug_information{slope_adjustment}{amount} = $slope_adjustment;
    }

    my $prob = $bs_probability + $slope_adjustment;

    return ($prob, \%debug_information);
}

sub _bs_formula_for {
    my $contract_type = shift;
    my $formula_path  = 'Math::Business::BlackScholes::Binaries::' . lc $contract_type;
    return \&$formula_path;
}

sub _greek_formula_for {
    my ($greek, $contract_type) = @_;
    my $formula_path = 'Math::Business::BlackScholes::Binaries::Greeks::' . ucfirst lc $greek . '::' . lc $contract_type;
    return \&$formula_path;
}

sub _pricing_args {
    my $self = shift;
    my %args = map { $_ => $self->$_ } @{$self->_formula_args};
    return \%args;
}

sub _to_array {
    my ($self, $params) = @_;
    my @array = map { ref $params->{$_} eq 'ARRAY' ? @{$params->{$_}} : $params->{$_} } @{$self->_formula_args};
    return @array;
}

sub _markup_config {
    my $market = shift;

    my $config = {
        forex       => [qw(traded_market_markup economic_event_markup end_of_day_markup butterfly_markup)],
        commodities => [qw(traded_market_markup economic_event_markup end_of_day_markup)],
        stocks      => [qw(traded_market_markup)],
        indices     => [qw(traded_market_markup)],
        futures     => [qw(traded_market_markup)],
        sectors     => [qw(traded_market_markup)],
    };

    my $markups = $config->{$market} // [];

    return {map { $_ => 1 } @$markups};
}

sub _get_first_tenor_on_surface {
    my $self = shift;

    my $original_surface = $self->market_data->{get_volsurface_data}->($self->underlying_symbol);
    my $first_term = (sort { $a <=> $b } keys %$original_surface)[0];
    return $first_term;
}

sub _get_vol_expiry {
    my $self = shift;

    return {expiry_date => $self->date_expiry} if $self->underlying_config->{market} eq 'forex';
    return {days => $self->timeindays};
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
