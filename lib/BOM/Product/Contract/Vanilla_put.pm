package BOM::Product::Contract::Vanilla_put;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier';

use BOM::Product::Pricing::Engine::BlackScholes;


sub ticks_to_expiry {
    die 'no ticks_to_expiry on a VANILLA_PUT contract';
}

sub _build_pricing_engine_name {
    return 'BOM::Product::Pricing::Engine::BlackScholes';
}

sub _build_pricing_engine {
    return BOM::Product::Pricing::Engine::BlackScholes->new({bet => shift});
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
