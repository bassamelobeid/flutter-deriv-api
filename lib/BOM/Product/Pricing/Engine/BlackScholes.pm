package BOM::Product::Pricing::Engine::BlackScholes;

=head1 NAME

BOM::Product::Pricing::Engine::BlackScholes

=head1 DESCRIPTION

Prices options using the GBM (Geometric Brownian Motion) model.

=cut

use Moose;

use List::Util qw(min max);

extends 'BOM::Product::Pricing::Engine';
with 'BOM::Product::Pricing::Engine::Role::StandardMarkup';

has _supported_types => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {
            CALL         => 1,
            PUT          => 1,
            RANGE        => 1,
            UPORDOWN     => 1,
            ONETOUCH     => 1,
            NOTOUCH      => 1,
            EXPIRYMISS   => 1,
            EXPIRYRANGE  => 1,
            VANILLA_CALL => 1,
            VANILLA_PUT  => 1,
        };
    },
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
