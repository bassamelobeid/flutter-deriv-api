package BOM::Product::Contract;    ## no critic ( RequireFilenameMatchesPackage )

use strict;
use warnings;

use JSON::MaybeXS;
use Math::Util::CalculatedValue::Validatable;
use List::Util qw(max);
use List::MoreUtils qw(none all);
use Format::Util::Numbers qw/financialrounding/;

use Price::Calculator;
use Quant::Framework::EconomicEventCalendar;
use Quant::Framework::Currency;
use Quant::Framework::CorrelationMatrix;
use Pricing::Engine::EuropeanDigitalSlope;
use Pricing::Engine::TickExpiry;
use Pricing::Engine::BlackScholes;
use Pricing::Engine::Lookback;
use LandingCompany::Commission qw(get_underlying_base_commission);

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::Product::Pricing::Greeks;
use BOM::Platform::Chronicle;
use BOM::Product::Pricing::Greeks::BlackScholes;
use BOM::Platform::Runtime;
use BOM::Product::ContractVol;
use BOM::Market::DataDecimate;
use BOM::Platform::Config;

## ATTRIBUTES  #######################

# Rates calculation, including quanto effects.
has [qw(mu discount_rate)] => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

has [qw(rho domqqq forqqq fordom)] => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

has priced_with => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

# a hash reference for slow migration of pricing engine to the new interface.
has new_interface_engine => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_new_interface_engine',
);

# we use pricing_engine_name matching all the time.
has priced_with_intraday_model => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_priced_with_intraday_model',
);

has price_calculator => (
    is         => 'ro',
    isa        => 'Price::Calculator',
    lazy_build => 1,
);

=head2 otm_threshold

An abbreviation for deep out of the money threshold. This is used to floor prices.

=cut

has otm_threshold => (
    is         => 'ro',
    lazy_build => 1,
);

# discounted_probability - The discounted total probability, given the time value of the money at stake.
# timeindays/timeinyears - note that for FX contracts of >=1 duration, these values will follow the market convention of integer days
has [qw(
        ask_probability
        theo_probability
        bid_probability
        discounted_probability
        )
    ] => (
    is         => 'ro',
    isa        => 'Math::Util::CalculatedValue::Validatable',
    lazy_build => 1,
    );

has [
    qw(q_rate
        r_rate
        pricing_mu
        )
    ] => (
    is         => 'rw',
    lazy_build => 1,
    );

has [
    qw( bid_price
        theo_price
        )
    ] => (
    is         => 'ro',
    init_arg   => undef,
    lazy_build => 1,
    );

has ask_price => (
    is         => 'ro',
    lazy_build => 1,
);

has [qw( pricing_engine_name )] => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

has pricing_engine => (
    is         => 'ro',
    lazy_build => 1,
);

has greek_engine => (
    is         => 'ro',
    isa        => 'BOM::Product::Pricing::Greeks',
    lazy_build => 1,
    handles    => [qw(delta vega theta gamma vanna volga)],
);

# pricing_new - Do we believe this to be a new unsold bet starting now (or later)?

has [qw(
        pricing_new
        )
    ] => (
    is         => 'ro',
    isa        => 'Bool',
    lazy_build => 1,
    );

# Application developer's commission.
# Defaults to 0%
has app_markup_percentage => (
    is      => 'ro',
    default => 0,
);

has [qw(app_markup_dollar_amount app_markup)] => (
    is         => 'ro',
    lazy_build => 1,
);

# base_commission can be overridden on contract type level.
# When this happens, underlying base_commission is ignored.
#
# min_commission_amount - the minimum commission charged per contract.
# E.g. if the payout currency is in USD, the minimum commission we want to charge is 2 cents. (min_commission_amount = 0.02)
has [qw(risk_markup commission_markup base_commission commission_from_stake min_commission_amount)] => (
    is         => 'ro',
    lazy_build => 1,
);

## METHODS  #######################
my $pc_params_setters = {
    timeinyears            => sub { my $self = shift; $self->price_calculator->timeinyears($self->timeinyears) },
    discount_rate          => sub { my $self = shift; $self->price_calculator->discount_rate($self->discount_rate) },
    staking_limits         => sub { my $self = shift; $self->price_calculator->staking_limits($self->staking_limits) },
    theo_probability       => sub { my $self = shift; $self->price_calculator->theo_probability($self->theo_probability) },
    commission_markup      => sub { my $self = shift; $self->price_calculator->commission_markup($self->commission_markup) },
    min_commission_amount  => sub { my $self = shift; $self->price_calculator->min_commission_amount($self->min_commission_amount) },
    commission_from_stake  => sub { my $self = shift; $self->price_calculator->commission_from_stake($self->commission_from_stake) },
    discounted_probability => sub { my $self = shift; $self->price_calculator->discounted_probability($self->discounted_probability) },
    probability            => sub {
        my $self = shift;
        my $probability;
        if ($self->new_interface_engine) {
            $probability = Math::Util::CalculatedValue::Validatable->new({
                name        => 'theo_probability',
                description => 'theoretical value of a contract',
                set_by      => $self->pricing_engine_name,
                base_amount => $self->pricing_engine->theo_probability,
                minimum     => 0,
                maximum     => 1,
            });
        } else {
            $probability = $self->pricing_engine->probability;
        }
        $self->price_calculator->theo_probability($probability);
    },
    opposite_ask_probability => sub {
        my $self = shift;
        $self->price_calculator->opposite_ask_probability($self->opposite_contract_for_sale->ask_probability);
    },
};

my $pc_needed_params_map = {
    theo_probability       => [qw/ probability /],
    ask_probability        => [qw/ theo_probability /],
    bid_probability        => [qw/ theo_probability discounted_probability opposite_ask_probability /],
    payout                 => [qw/ theo_probability commission_from_stake /],
    commission_markup      => [qw/ theo_probability min_commission_amount/],
    commission_from_stake  => [qw/ theo_probability commission_markup /],
    validate_price         => [qw/ theo_probability commission_markup commission_from_stake staking_limits /],
    discounted_probability => [qw/ timeinyears discount_rate /],
};

sub commission_multiplier {
    return shift->price_calculator->commission_multiplier(@_);
}

sub _set_price_calculator_params {
    my ($self, $method) = @_;

    for my $key (@{$pc_needed_params_map->{$method}}) {
        $pc_params_setters->{$key}->($self);
    }
    return;
}

sub _create_new_interface_engine {
    my $self = shift;
    return if not $self->new_interface_engine;

    my %pricing_parameters;

    my $payouttime_code = ($self->payouttime eq 'hit') ? 0 : 1;
    my %contract_config = (
        contract_type     => $self->pricing_code,
        underlying_symbol => $self->underlying->symbol,
        date_start        => $self->effective_start,
        date_pricing      => $self->date_pricing,
        date_expiry       => $self->date_expiry,
        payouttime_code   => $payouttime_code,
        for_date          => $self->underlying->for_date,
        spot              => $self->pricing_spot,
        strikes           => [grep { $_ } values %{$self->barriers_for_pricing}],
        priced_with       => $self->priced_with,
        payout_type       => $self->payout_type,
        is_atm_contract   => $self->is_atm_bet,
    );

    if ($self->pricing_engine_name eq 'Pricing::Engine::Digits') {
        %pricing_parameters = (
            strike => $self->barrier ? $self->barrier->as_absolute : undef,
            contract_type => $self->pricing_code,
        );
    } elsif ($self->pricing_engine_name eq 'Pricing::Engine::TickExpiry') {
        my $backprice = ($self->underlying->for_date) ? 1 : 0;
        # do not discount for EURUSD because because we have high tick expiry volume on it. We might revise this in the future.
        my $apply_equal_tick_discount = ($self->code eq 'CALLE' or $self->code eq 'PUTE' or $self->underlying->symbol eq 'frxEURUSD') ? 0 : 1;
        %pricing_parameters = (
            apply_equal_tick_discount => $apply_equal_tick_discount,
            contract_type             => $self->pricing_code,
            underlying_symbol         => $self->underlying->symbol,
            date_start                => $self->effective_start,
            date_pricing              => $self->date_pricing,
            ticks                     => BOM::Market::DataDecimate->new()->tick_cache_get_num_ticks({
                    underlying => $self->underlying,
                    end_epoch  => $self->date_start->epoch,
                    num        => 20,
                    backprice  => $backprice,

                }
            ),
            economic_events => _generate_market_data(
                $self->underlying,
                $self->date_start
            )->{economic_events},
        );
    } elsif ($self->pricing_engine_name eq 'Pricing::Engine::EuropeanDigitalSlope') {
        #pricing_vol can be calculated using an empirical vol. So we have to sent the raw numbers
        %pricing_parameters = (
            %contract_config,
            chronicle_reader         => BOM::Platform::Chronicle::get_chronicle_reader($self->underlying->for_date),
            discount_rate            => $self->discount_rate,
            mu                       => $self->mu,
            vol                      => $self->pricing_vol_for_two_barriers // $self->pricing_vol,
            q_rate                   => $self->q_rate,
            r_rate                   => $self->r_rate,
            volsurface               => $self->volsurface->surface,
            volsurface_creation_date => $self->volsurface->creation_date,
        );
    } elsif ($self->pricing_engine_name eq 'Pricing::Engine::BlackScholes') {
        %pricing_parameters = (
            %contract_config,
            t             => $self->timeinyears->amount,
            discount_rate => $self->discount_rate,
            mu            => $self->mu,
            vol           => $self->pricing_vol_for_two_barriers // $self->pricing_vol,
        );
    } elsif ($self->pricing_engine_name eq 'Pricing::Engine::Lookback') {
        %pricing_parameters = (
            strikes         => [grep { $_ } values %{$self->barriers_for_pricing}],
            spot            => $self->pricing_spot,
            discount_rate   => $self->discount_rate,
            t               => $self->timeinyears->amount,
            mu              => $self->mu,
            vol             => $self->pricing_vol,
            payouttime_code => $payouttime_code,
            payout_type     => 'non-binary',
            contract_type   => $self->pricing_code,
            spot_max        => $self->spot_max,
            spot_min        => $self->spot_min,
        );
    } else {
        die "Unknown pricing engine: " . $self->pricing_engine_name;
    }

    if (my @missing_parameters = grep { !exists $pricing_parameters{$_} } @{$self->pricing_engine_name->required_args}) {
        die "Missing pricing parameters for engine " . $self->pricing_engine_name . " - " . join ',', @missing_parameters;
    }

    return $self->pricing_engine_name->new(%pricing_parameters);
}

sub _generate_market_data {
    my ($underlying, $date_start) = @_;

    my $for_date = $underlying->for_date;
    my $result   = {};

    #this is a list of symbols which are applicable when getting important economic events.
    #Note that other than currency pair of the fx symbol, we include some other important currencies
    #here because any event for these currencies, can potentially affect all other currencies too
    my %applicable_symbols = (
        USD                                 => 1,
        AUD                                 => 1,
        CAD                                 => 1,
        CNY                                 => 1,
        NZD                                 => 1,
        $underlying->quoted_currency_symbol => 1,
        $underlying->asset_symbol           => 1,
    );

    my $ee = Quant::Framework::EconomicEventCalendar->new({
            chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader($for_date),
        }
        )->get_latest_events_for_period({
            from => $date_start->minus_time_interval('10m'),
            to   => $date_start->plus_time_interval('10m')
        },
        $for_date
        );

    my @applicable_news =
        sort { $a->{release_date} <=> $b->{release_date} } grep { $applicable_symbols{$_->{symbol}} } @$ee;

    #as of now, we only update the result with a raw list of economic events, later that we move to other
    #engines, we will add other market-data items too (e.g. dividends, vol-surface, ...)
    $result->{economic_events} = \@applicable_news;
    return $result;
}

=head2 market_is_inefficient

Returns true or false. Note that the value may vary depending on date_pricing.

=cut

sub market_is_inefficient {
    my $self = shift;

    # market inefficiency only applies to forex and commodities.
    return 0 unless ($self->market->name eq 'forex' or $self->market->name eq 'commodities');
    return 0 if $self->expiry_daily;

    my $hour = $self->date_pricing->hour + 0;
    # only 20:00/21:00 GMT to end of day
    my $disable_hour = $self->date_pricing->is_dst_in_zone('America/New_York') ? 20 : 21;
    return 0 if $hour < $disable_hour;
    return 1;
}

## BUILDERS  #######################

sub _build_domqqq {
    my $self = shift;

    my $result = {};

    if ($self->priced_with eq 'quanto') {
        $result->{underlying} = create_underlying({
            symbol   => 'frx' . $self->underlying->quoted_currency_symbol . $self->currency,
            for_date => $self->underlying->for_date
        });
        $result->{volsurface} = $self->_volsurface_fetcher->fetch_surface({
            underlying => $result->{underlying},
        });
    } else {
        $result = $self->fordom;
    }

    return $result;
}

sub _build_forqqq {
    my $self = shift;

    my $result = {};

    if ($self->priced_with eq 'quanto' and ($self->underlying->market->name eq 'forex' or $self->underlying->market->name eq 'commodities')) {
        $result->{underlying} = create_underlying({
            symbol   => 'frx' . $self->underlying->asset_symbol . $self->currency,
            for_date => $self->underlying->for_date
        });

        $result->{volsurface} = $self->_volsurface_fetcher->fetch_surface({
            underlying => $result->{underlying},
        });

    } else {
        $result = $self->domqqq;
    }

    return $result;
}

sub _build_otm_threshold {
    my $self = shift;

    my $custom_otm       = JSON::MaybeXS->new->decode(BOM::Platform::Runtime->instance->app_config->quants->custom_otm_threshold // {});
    my @known_conditions = qw(expiry_type is_atm_bet);
    my %mapper           = (
        underlying_symbol => $self->underlying->symbol,
        market            => $self->market->name,
    );

    # underlying symbol supercedes market
    foreach my $symbol (qw(underlying_symbol market)) {
        my $value = 0;
        foreach my $data_ref (values %$custom_otm) {
            my $conditions = $data_ref->{conditions};

            if (defined $conditions->{$symbol} and $conditions->{$symbol} eq $mapper{$symbol}) {
                my $match = not first { $conditions->{$_} ne $self->$_ } grep { $conditions->{$_} } @known_conditions;
                $value = max($value, $data_ref->{value}) if $match;
            }
        }
        # returns if it is a non-zero value
        return $value if $value > 0;
    }

    # this is the default depp OTM threshold set in yaml per market
    return $self->market->deep_otm_threshold;
}

sub _build_app_markup {
    return shift->price_calculator->app_markup;
}

sub _build_app_markup_dollar_amount {
    my $self = shift;

    return financialrounding('amount', $self->currency, $self->app_markup->amount * $self->payout);
}

#this is supposed to be called for legacy pricing engines (not new interface)
sub _build_risk_markup {
    my $self = shift;

    my $base_amount = 0;
    if ($self->pricing_engine and $self->pricing_engine->can('risk_markup')) {
        $base_amount = $self->new_interface_engine ? $self->pricing_engine->risk_markup : $self->pricing_engine->risk_markup->amount;
    } elsif ($self->new_interface_engine) {
        $base_amount = $self->debug_information->{risk_markup}->{amount};
    }

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'risk_markup',
        description => 'Risk markup for a pricing model',
        set_by      => $self->pricing_engine_name,
        base_amount => $base_amount,
    });
}

sub _build_base_commission {
    my $self = shift;

    my $market_name        = $self->market->name;
    my $per_market_scaling = BOM::Platform::Runtime->instance->app_config->quants->commission->adjustment->per_market_scaling->$market_name;
    my $args               = {underlying_symbol => $self->underlying->symbol};
    if ($self->can('landing_company')) {
        $args->{landing_company} = $self->landing_company;
    }
    my $underlying_base = get_underlying_base_commission($args);

    # we are adding extra commission on these contracts for volatility indices because we have clients taking advantage of our fixed feed generation
    # frequency (every 2-second a tick on the even second). By buying a 15-second  deep ITM contract on the even second, the actual contract duration is 14-second because
    # we will always use the previous tick to settle the contract. Shorter deep ITM contract is more expensive, so the client is paying cheaper for a 14-second contract.
    if (not $self->for_sale and $self->market->name eq 'volidx' and not $self->is_atm_bet and $self->remaining_time->seconds < 60) {
        $underlying_base = 0.023;
    }

    if (not $self->for_sale and $self->market->name eq 'forex' and $self->is_atm_bet) {
        $underlying_base = 0.05;
    }

    return $underlying_base * $per_market_scaling / 100;
}

sub _build_commission_markup {
    my $self = shift;

    $self->_set_price_calculator_params('commission_markup');
    return $self->price_calculator->commission_markup;
}

sub _build_commission_from_stake {
    my $self = shift;

    $self->_set_price_calculator_params('commission_from_stake');
    return $self->price_calculator->commission_from_stake;
}

sub _build_theo_price {
    my $self = shift;

    return $self->_price_from_prob('theo_probability');
}

sub _build_new_interface_engine {
    my $self = shift;

    my %engines = (
        'Pricing::Engine::BlackScholes'         => 1,
        'Pricing::Engine::Digits'               => 1,
        'Pricing::Engine::TickExpiry'           => 1,
        'Pricing::Engine::EuropeanDigitalSlope' => 1,
        'Pricing::Engine::Lookback'             => 1,
    );

    return $engines{$self->pricing_engine_name} // 0;
}

sub _build_fordom {
    my $self = shift;

    return {
        underlying => $self->underlying,
        volsurface => $self->volsurface,
    };
}

sub _build_discount_rate {
    my $self = shift;

    my %args = (
        symbol => $self->currency,
        $self->underlying->for_date ? (for_date => $self->underlying->for_date) : (),
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader($self->underlying->for_date),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    );
    my $curr_obj = Quant::Framework::Currency->new(%args);

    return $curr_obj->rate_for($self->timeinyears->amount);
}

sub _build_priced_with {
    my $self = shift;

    my $underlying = $self->underlying;

    # Everything should have a quoted currency, except our randoms.
    # However, rather than check for random directly, just do a numeraire bet if we don't know what it is.
    my $priced_with;
    if ($underlying->quoted_currency_symbol eq $self->currency or (none { $underlying->market->name eq $_ } (qw(forex commodities indices)))) {
        $priced_with = 'numeraire';
    } elsif ($underlying->asset_symbol eq $self->currency) {
        $priced_with = 'base';
    } else {
        $priced_with = 'quanto';
    }

    if ($underlying->submarket->name eq 'smart_fx') {
        $priced_with = 'numeraire';
    }

    return $priced_with;
}

sub _build_mu {
    my $self = shift;

    my $mu = $self->r_rate - $self->q_rate;

    if (first { $self->underlying->market->name eq $_ } (qw(forex commodities indices))) {
        my $rho = $self->rho->{fd_dq};
        my $vol = $self->atm_vols;
        # See [1] for Quanto Formula
        $mu = $self->r_rate - $self->q_rate - $rho * $vol->{fordom} * $vol->{domqqq};
    }

    return $mu;
}

sub _build_rho {

    my $self     = shift;
    my $atm_vols = $self->atm_vols;
    my $w        = ($self->domqqq->{underlying}->inverted) ? -1 : 1;

    my %rhos;

    $rhos{fd_dq} = 0;

    if ($self->priced_with eq 'numeraire') {
        $rhos{fd_dq} = 0;
    } elsif ($self->priced_with eq 'base') {
        $rhos{fd_dq} = -1;
    } elsif ($self->underlying->market->name eq 'forex' or $self->underlying->market->name eq 'commodities') {
        $rhos{fd_dq} =
            $w * (($atm_vols->{forqqq}**2 - $atm_vols->{fordom}**2 - $atm_vols->{domqqq}**2) / (2 * $atm_vols->{fordom} * $atm_vols->{domqqq}));
    } elsif ($self->underlying->market->name eq 'indices') {
        my $cr             = BOM::Platform::Chronicle::get_chronicle_reader($self->underlying->for_date);
        my $construct_args = {
            symbol           => $self->underlying->market->name,
            for_date         => $self->underlying->for_date,
            chronicle_reader => $cr,
        };
        my $rho_data           = Quant::Framework::CorrelationMatrix->new($construct_args);
        my $expiry_conventions = Quant::Framework::ExpiryConventions->new(
            underlying       => $self->underlying,
            chronicle_reader => $cr,
            calendar         => $self->trading_calendar,
        );

        my $index           = $self->underlying->asset_symbol;
        my $payout_currency = $self->currency;
        my $tiy             = $self->timeinyears->amount;

        $rhos{fd_dq} = $rho_data->correlation_for($index, $payout_currency, $tiy, $expiry_conventions);
    }

    return \%rhos;
}

sub _build_price_calculator {
    my $self = shift;

    return Price::Calculator->new({
        currency              => $self->currency,
        deep_otm_threshold    => $self->otm_threshold,
        base_commission       => $self->base_commission,
        app_markup_percentage => $self->app_markup_percentage,
        ($self->has_commission_markup)      ? (commission_markup      => $self->commission_markup)      : (),
        ($self->has_commission_from_stake)  ? (commission_from_stake  => $self->commission_from_stake)  : (),
        ($self->has_payout)                 ? (payout                 => $self->payout)                 : (),
        ($self->has_ask_price)              ? (ask_price              => $self->ask_price)              : (),
        ($self->has_theo_probability)       ? (theo_probability       => $self->theo_probability)       : (),
        ($self->has_ask_probability)        ? (ask_probability        => $self->ask_probability)        : (),
        ($self->has_discounted_probability) ? (discounted_probability => $self->discounted_probability) : (),
    });
}

sub _build_bid_price {
    my $self = shift;

    return $self->_price_from_prob('bid_probability');
}

sub _build_ask_price {
    my $self = shift;

    return $self->_price_from_prob('ask_probability');
}

sub _build_greek_engine {
    my $self = shift;
    return BOM::Product::Pricing::Greeks::BlackScholes->new({bet => $self});
}

sub _build_pricing_engine_name {
    my $self = shift;

    my $engine_name = $self->is_path_dependent ? 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated' : 'Pricing::Engine::EuropeanDigitalSlope';

    #For Volatility indices, we use plain BS formula for pricing instead of VV/Slope
    $engine_name = 'Pricing::Engine::BlackScholes' if $self->market->name eq 'volidx';

    if ($self->tick_expiry) {
        my @symbols = create_underlying_db->get_symbols_for(
            market            => 'forex',     # forex is the only financial market that offers tick expiry contracts for now.
            contract_category => 'callput',
            expiry_type       => 'tick',
        );
        $engine_name = 'Pricing::Engine::TickExpiry' if _match_symbol(\@symbols, $self->underlying->symbol);
    } elsif (my $intraday_engine_name = $self->_check_intraday_engine_compatibility) {
        $engine_name = $intraday_engine_name;
    }

    return $engine_name;
}

sub _check_intraday_engine_compatibility {
    my $self = shift;

    my $engine_name =
        $self->market->name eq 'indices' ? 'BOM::Product::Pricing::Engine::Intraday::Index' : 'BOM::Product::Pricing::Engine::Intraday::Forex';

    return $engine_name->get_compatible('basic', $self->metadata);
}

sub _build_pricing_engine {
    my $self = shift;

    return $self->_create_new_interface_engine if $self->new_interface_engine;

    my $pricing_engine = $self->pricing_engine_name->new({
        bet                => $self,
        inefficient_period => $self->market_is_inefficient,
        $self->priced_with_intraday_model ? (economic_events => $self->economic_events_for_volatility_calculation) : (),
    });

    return $pricing_engine;
}

sub _build_pricing_mu {
    my $self = shift;

    return $self->mu;
}

sub _build_r_rate {
    my $self = shift;

    return $self->underlying->interest_rate_for($self->timeinyears->amount);
}

sub _build_q_rate {
    my $self = shift;

    my $underlying = $self->underlying;
    my $q_rate     = $underlying->dividend_rate_for($self->timeinyears->amount);

    return $q_rate;
}

sub _build_pricing_new {
    my $self = shift;

    # do not use $self->date_pricing here because milliseconds matters!
    # _date_pricing_milliseconds will not be set if date_pricing is not built.
    my $time = $self->_date_pricing_milliseconds // $self->date_pricing->epoch;
    return 0 if $time > $self->date_start->epoch;
    return 1;
}

sub _match_symbol {
    my ($lists, $symbol) = @_;
    for (@$lists) {
        return 1 if $_ eq $symbol;
    }
    return;
}

sub _build_min_commission_amount {
    my $self = shift;

    my $static = BOM::Platform::Config::quants;

    return $static->{bet_limits}->{min_commission_amount}->{$self->currency} // 0;
}

1;
