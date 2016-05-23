package BOM::Product::Pricing::Engine::Asian;

use 5.010;
use Moose;
extends 'BOM::Product::Pricing::Engine';

use Math::Util::CalculatedValue::Validatable;

has _supported_types => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {
            CALL => 1,
            PUT  => 1,
        };
    },
);

has [qw(probablity)] => (
    is         => 'ro',
    isa        => 'Math::Util::CalculatedValue::Validatable',
    lazy_build => 1,
);

sub _build_probability {
    my $self = shift;

    my $p = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theoretical_probability',
        description => 'Theoretical probability for asian',
        set_by      => __PACKAGE__,
        base_amount => $self->bs_probability->amount,
    });

    return $p;
}

has [qw(commission_markup)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_commission_markup {
    my $self = shift;

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'commission_markup',
        description => 'equivalent to tick trades',
        set_by      => __PACKAGE__,
        base_amount => 0.015,
    });
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
