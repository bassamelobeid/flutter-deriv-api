package BOM::Product::Pricing::Greeks::ZeroGreek;

use Moose;

# Non-financial contracts, just zero out all of the greeks.
extends 'BOM::Product::Pricing::Greeks';

override get_greek => sub {
    return 0;
};

no Moose;
__PACKAGE__->meta->make_immutable;
1;
