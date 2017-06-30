package BOM::Product::Contract::Binaryico;

use Moose;
extends 'BOM::Product::Contract::Coinauction';

sub code { return 'BINARYICO' }

no Moose;
__PACKAGE__->meta->make_immutable;
1;
