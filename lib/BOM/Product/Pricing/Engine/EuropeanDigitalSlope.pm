package BOM::Product::Pricing::Engine::EuropeanDigitalSlope;

=head1 NAME

BOM::Product::Pricing::Engine::EuropeanDigitalSlope

=head1 DESCRIPTION

Provides the European digital slope pricing with our markup.

=cut

use Moose;

extends 'Pricing::Engine::EuropeanDigitalSlope';
with 'BOM::Product::Pricing::Engine::Role::StandardMarkup';

no Moose;
__PACKAGE__->meta->make_immutable;
1;
