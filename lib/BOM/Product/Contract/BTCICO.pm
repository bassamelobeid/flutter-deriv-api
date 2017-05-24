package BOM::Product::Contract::BTCICO;

use Moose;
extends 'BOM::Product::Contract::Coinauction';


sub code {return 'BTCICO'};


no Moose;
__PACKAGE__->meta->make_immutable;
1;
