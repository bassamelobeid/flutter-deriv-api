package BOM::Product::Pricing::Greeks::BlackScholes;

use Moose;

# The base class just implements this behaviour.
# To be reconsidered in the utue, perhaps.
extends 'BOM::Product::Pricing::Greeks';

no Moose;
__PACKAGE__->meta->make_immutable;
1;
