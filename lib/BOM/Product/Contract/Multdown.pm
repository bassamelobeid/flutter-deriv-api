package BOM::Product::Contract::Multdown;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Multiplier';

no Moose;
__PACKAGE__->meta->make_immutable;
1;
