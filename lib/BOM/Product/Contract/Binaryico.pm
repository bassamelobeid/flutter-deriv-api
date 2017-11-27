package BOM::Product::Contract::Binaryico;

use Moose;
extends 'BOM::Product::Contract::Coinauction';

sub code { return 'BINARYICO' }

# Binary ICO bids does not settle automatically
sub may_settle_automatically {
    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
