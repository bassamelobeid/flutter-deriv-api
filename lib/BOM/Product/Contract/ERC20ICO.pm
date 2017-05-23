package BOM::Product::Contract::ERC20ICO;

use Moose;
extends 'BOM::Product::Contract::Coinauction';


sub code {return 'ERC20ICO'};


no Moose;
__PACKAGE__->meta->make_immutable;
1;
