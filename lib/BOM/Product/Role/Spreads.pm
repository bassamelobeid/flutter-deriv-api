package BOM::Product::Role::Spreads;

use Moose::Role;
# Spreads is a double barrier contract that expires at contract expiration time.
with 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use Pricing::Engine::Spreads;
use BOM::Product::Static;
use List::Util qw(max min);

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

use constant {
    MINIMUM_ASK_PRICE => 0.50,
    MINIMUM_BID_PRICE => 0,
};

override '_build_ask_price' => sub {
    my $self = shift;

    return max(MINIMUM_ASK_PRICE, min($self->payout, ($self->_theo_price + $self->commission_per_unit) * $self->multiplier));
};

override '_build_bid_price' => sub {
    my $self = shift;

    return max(MINIMUM_BID_PRICE, min($self->payout, $self->ask_price - 2 * $self->commission_per_unit * $self->multiplier));
};

override _build_base_commission => sub {
    my $self = shift;

    my $args = {underlying_symbol => $self->underlying->symbol};
    if ($self->can('landing_company')) {
        $args->{landing_company} = $self->landing_company;
    }
    my $underlying_base = get_underlying_base_commission($args);
    return $underlying_base;
};

=head2 commission_per_unit

Return commission of the contract in dollar amount for one unit, not percentage.
A minimum commission of 1 cent is charged for each unit.

=cut

sub commission_per_unit {
    my $self = shift;

    # base_commission is in percentage
    my $base = $self->base_commission;

    return max(0.01, $self->_theo_price * $base);
}

=head2 multiplier

Multiplier for non-binary contract.

=cut

# keep this as a method to prevent user input
sub multiplier {
    my $self = shift;

    return $self->payout / ($self->high_barrier->as_absolute - $self->low_barrier->as_absolute);
}

=head2 ticks_to_expiry

The number of ticks required from contract start time to expiry.

=cut

sub ticks_to_expiry {
    # Add one since we want N ticks *after* the entry spot
    return shift->tick_count + 1;
}

## PRIVATE ##
sub _theo_price {
    my $self = shift;

    my @strikes = ($self->high_barrier->as_absolute, $self->low_barrier->as_absolute);
    my $vol_args = {
        from => $self->effective_start->epoch,
        to   => $self->date_expiry->epoch,
        spot => $self->current_spot,
    };

    my @vols = map { $self->volsurface->get_volatility(+{%$vol_args, strike => $_}) } @strikes;

    my $theo_price = Pricing::Engine::Spreads->new(
        spot          => $self->current_spot,
        strikes       => \@strikes,
        discount_rate => $self->discount_rate,
        t             => $self->timeinyears->amount,
        mu            => $self->mu,
        vols          => \@vols,
        contract_type => $self->pricing_code,
    )->theo_price;
}
1;
