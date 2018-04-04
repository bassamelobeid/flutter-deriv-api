package BOM::Product::Role::Bullspread;

use Moose::Role;
# Bullspread is a double barrier contract that expires at contract expiration time.
with 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Product::Pricing::Engine::BullSpread;
use BOM::Product::Static;

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

sub ticks_to_expiry {
    # Add one since we want N ticks *after* the entry spot
    return shift->tick_count + 1;
}

override '_build_ask_price' => sub {
    my $self = shift;

    return $self->_calculate_price_for({
        spot    => $self->pricing_spot,
        strikes => [$self->high_barrier->as_absolute, $self->low_barrier->as_absolute],
    });
};

override 'is_valid_to_sell' => sub {
    my $self = shift;

    $self->add_error({
        message           => 'resale is not offerred',
        message_to_client => [$ERROR_MAPPING->{ResaleNotOffered}],
    });

    return 0;
};

=head2 multiplier

Multiplier for non-binary contract.

=cut

# keep this as a method to prevent user input
sub multiplier {
    my $self = shift;

    return $self->payout / ($self->high_barrier->as_absolute - $self->low_barrier->as_absolute);
}

sub _calculate_price_for {
    my ($self, $args) = @_;

    my $vol_args = {
        from => $self->effective_start->epoch,
        to   => $self->date_expiry->epoch,
        spot => $args->{spot},
    };

    my @vols = map { $self->volsurface->get_volatility(+{%$vol_args, strike => $_}) } @{$args->{strikes}};

    return BOM::Product::Pricing::Engine::BullSpread->new(
        spot          => $args->{spot},
        strikes       => $args->{strikes},
        discount_rate => $self->discount_rate,
        t             => $self->timeinyears->amount,
        mu            => $self->mu,
        vols          => \@vols,
        contract_type => $self->pricing_code,
    )->theo_price;
}

1;
