package BOM::Product::Pricing::Engine::Intraday;

=head1 NAME

BOM::Product::Pricing::Engine::Intraday

=head1 DESCRIPTION

Price digital options with current realized vols and adjustments

=cut

use Moose;
extends 'BOM::Product::Pricing::Engine';
with 'BOM::Product::Pricing::Engine::Role::StandardMarkup';

use BOM::Market::DataDecimate;

=head2 tick_source

The source of the ticks used for this pricing. 

=cut

has tick_source => (
    is      => 'ro',
    default => sub {
        BOM::Market::DataDecimate->new;
    },
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
