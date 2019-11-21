package BOM::Product::Contract::Multup;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Multiplier';

no Moose;
__PACKAGE__->meta->make_immutable;
1;
