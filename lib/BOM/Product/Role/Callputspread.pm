package BOM::Product::Role::Callputspread;

use Moose::Role;
# Spreads is a double barrier contract that expires at contract expiration time.
with 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::ExpireAtEnd', 'BOM::Product::Role::NonBinary';

use LandingCompany::Commission qw(get_underlying_base_commission);
use Format::Util::Numbers qw/financialrounding/;
use List::Util qw(min);
use List::MoreUtils qw(any);
use Pricing::Engine::Callputspread;
use YAML::XS qw(LoadFile);

use Math::Util::CalculatedValue::Validatable;

use BOM::Product::Exception;
use BOM::Config::QuantsConfig;
use BOM::Config;

use constant {
    MINIMUM_BID_PRICE => 0,
};

=head2 user_defined_multiplier
price per unit is not rounded to the nearest cent because we could get price below one cent.
=cut

has user_defined_multiplier => (
    is      => 'ro',
    default => 0,
);

has minimum_commission_per_contract => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_minimum_commission_per_contract {
    my $self = shift;

    my $static = BOM::Config::quants;

    return $static->{bet_limits}->{min_commission_amount}->{callputspread}->{$self->currency};
}

override '_build_ask_price' => sub {
    my $self = shift;

    return $self->_user_input_stake if defined $self->_user_input_stake;

    my $ask_price          = $self->theo_price + $self->commission;
    my $commission_charged = $self->commission;

    # callput spread can have a price per unit for less than 1 cent for forex contracts.
    # Hence, we removed the minimums on commission per unit and ask price per unit.
    # But, we need to make sure we can at least 50 cents commission per contract.
    if ($commission_charged < $self->minimum_commission_per_contract) {
        $ask_price = $ask_price - $commission_charged + $self->minimum_commission_per_contract;
    }

    $ask_price = financialrounding('price', $self->currency, min($self->maximum_ask_price, $ask_price));

    # publish ask price to pricing server
    $self->_publish({ask_price => $ask_price});

    return $ask_price;
};

=head2 theo_price
price per unit.
=cut

override '_build_theo_price' => sub {
    my $self = shift;

    return $self->pricing_engine->theo_price;
};

=head2 base_commission
base commission for this contract. Usually derived from the underlying instrument that we are pricing.
=cut

override _build_base_commission => sub {
    my $self = shift;

    my $args = {underlying_symbol => $self->underlying->symbol};
    if ($self->can('landing_company')) {
        $args->{landing_company} = $self->landing_company;
    }
    my $underlying_base = get_underlying_base_commission($args);
    return $underlying_base;
};

override '_build_pricing_engine' => sub {
    my $self = shift;

    my @strikes = ($self->high_barrier->as_absolute, $self->low_barrier->as_absolute);
    my $pen     = $self->pricing_engine_name;

    my @vols = @{$self->pricing_vol_for_two_barriers}{'high_barrier_vol', 'low_barrier_vol'};

    my $bet_duration = $self->timeindays->amount * 24 * 60;
    # Maximum lookback period is 30 minutes
    my $lookback_duration = min(30, $bet_duration);

    my $min_max = $self->spot_min_max($self->date_start->minus_time_interval($lookback_duration . 'm'));

    my $rollover_hour = $self->underlying->market->name eq 'forex' ? $self->volsurface->rollover_date($self->date_pricing) : undef;

    my %markup_params = (
        apply_mean_reversion_markup => $self->apply_mean_reversion_markup,
        min_max                     => $min_max,
        custom_commission           => $self->_custom_commission,
        effective_start             => $self->effective_start,
        date_expiry                 => $self->date_expiry,
        barrier_tier                => $self->barrier_tier,
        symbol                      => $self->underlying->symbol,
        economic_events             => $self->economic_events_for_volatility_calculation,
        apply_quiet_period_markup   => $self->apply_quiet_period_markup,
        payout                      => $self->payout,
        apply_rollover_markup       => $self->apply_rollover_markup,
        rollover_date               => $rollover_hour,
        interest_rate_difference    => $self->q_rate - $self->r_rate,
        date_start                  => $self->date_start,
        multiplier                  => $self->multiplier,
        market                      => $self->underlying->market->name,
        market_is_inefficient       => $self->market_is_inefficient,
        contract_category           => $self->category->code,
        hour_end_markup_parameters  => $self->hour_end_markup_parameters,
        enable_hour_end_discount    => BOM::Config::Runtime->instance->app_config->quants->enable_hour_end_discount,
        apply_equal_tie_markup => 0, # do not apply equal tick markup for callputspreads since equal tick does NOT give you full payout (like binary).
    );

    return $self->pricing_engine_name->new(
        %markup_params,
        spot          => $self->current_spot,
        strikes       => \@strikes,
        discount_rate => $self->discount_rate,
        t             => $self->timeinyears->amount,
        mu            => $self->mu,
        vols          => \@vols,
        contract_type => $self->pricing_code,
    );
};

=head2 multiplier
Multiplier for non-binary contract.
=cut

sub multiplier {
    my $self = shift;

    return $self->payout / ($self->high_barrier->as_absolute - $self->low_barrier->as_absolute);
}

sub minimum_bid_price {
    return MINIMUM_BID_PRICE;
}

sub maximum_ask_price {
    my $self = shift;
    return $self->payout;
}

sub maximum_bid_price {
    my $self = shift;
    return $self->payout;
}

sub maximum_payout {
    my $self = shift;
    return $self->payout;
}

=head2 ticks_to_expiry

The number of ticks required from contract start time to expiry.

=cut

sub ticks_to_expiry {
    my $self = shift;
    return BOM::Product::Exception->throw(
        error_code => 'InvalidTickExpiry',
        error_args => [$self->code],
        details    => {field => 'duration'},
    );
}

override '_build_pricing_engine_name' => sub {
    return 'Pricing::Engine::Callputspread';
};

sub apply_mean_reversion_markup {
    my $self = shift;

    my $bet_duration = $self->timeindays->amount * 24 * 60;
    # Maximum lookback period is 30 minutes
    my $lookback_duration = min(30, $bet_duration);
    #  We did not do any ajdusment if there is nothing to lookback ie either monday morning or the next day after early close
    return $self->trading_calendar->is_open_at($self->underlying->exchange, $self->date_start->minus_time_interval($lookback_duration . 'm')) ? 1 : 0;
}

sub apply_quiet_period_markup {
    my $self = shift;

    my $apply_flag =
        ($self->trading_calendar->is_open_at($self->underlying->exchange, $self->date_start) and $self->is_in_quiet_period($self->date_pricing))
        ? 1
        : 0;

    return $apply_flag;
}

1;
