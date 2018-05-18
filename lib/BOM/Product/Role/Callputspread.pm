package BOM::Product::Role::Callputspread;

use Moose::Role;
# Spreads is a double barrier contract that expires at contract expiration time.
with 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::ExpireAtEnd', 'BOM::Product::Role::NonBinary';

use LandingCompany::Commission qw(get_underlying_base_commission);
use Format::Util::Numbers qw/financialrounding/;
use List::Util qw(min);
use Pricing::Engine::Callputspread;

use BOM::Product::Exception;

use constant {
    MINIMUM_BID_PRICE               => 0,
    MINIMUM_COMMISSION_PER_CONTRACT => 0.5,    # 50 cents commission per contract
};

=head2 user_defined_multiplier
price per unit is not rounded to the nearest cent because we could get price below one cent.
=cut

has user_defined_multiplier => (
    is      => 'ro',
    default => 0,
);

override '_build_ask_price' => sub {
    my $self = shift;

    my $ask_price          = $self->_ask_price_per_unit * $self->multiplier;
    my $commission_charged = $self->commission_per_unit * $self->multiplier;

    # callput spread can have a price per unit for less than 1 cent for forex contracts.
    # Hence, we removed the minimums on commission per unit and ask price per unit.
    # But, we need to make sure we can at least 10 cents commission per contract.
    if ($commission_charged < MINIMUM_COMMISSION_PER_CONTRACT) {
        $ask_price = $ask_price - $commission_charged + MINIMUM_COMMISSION_PER_CONTRACT;
    }

    $ask_price = min($self->maximum_ask_price, $ask_price);

    return financialrounding('price', $self->currency, $ask_price);
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
    my $vol_args = {
        from => $self->effective_start->epoch,
        to   => $self->date_expiry->epoch,
        spot => $self->current_spot,
    };

    my @vols = map { $self->volsurface->get_volatility(+{%$vol_args, strike => $_}) } @strikes;

    return $self->pricing_engine_name->new(
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

=head2 ticks_to_expiry

The number of ticks required from contract start time to expiry.

=cut

sub ticks_to_expiry {
    my $self = shift;
    return BOM::Product::Exception->throw(
        error_code => 'InvalidTickExpiry',
        error_args => [$self->code],
    );
}

override '_build_pricing_engine_name' => sub {
    return 'Pricing::Engine::Callputspread';
};

override allowed_amount_type => sub {
    return {
        payout => 1,
    };
};

1;
