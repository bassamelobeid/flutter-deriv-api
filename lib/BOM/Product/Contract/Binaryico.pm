package BOM::Product::Contract::BinaryICO;

use Moose;
extends 'BOM::Product::Contract::Coinauction';

sub code { return 'BinaryICO' }

no Moose;
__PACKAGE__->meta->make_immutable;
1;
