package BOM::Product::Contract::Vanilla_put;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier';

use BOM::Product::Pricing::Engine::BlackScholes;

sub code          { return 'VANILLA_PUT'; }
sub pricing_code  { return 'VANILLA_PUT'; }
sub category_code { return 'vanilla'; }
sub payout_type   { return 'non-binary'; }
sub payouttime    { return 'end'; }

sub _build_pricing_engine_name {
    return 'BOM::Product::Pricing::Engine::BlackScholes';
}

sub _build_pricing_engine {
    return BOM::Product::Pricing::Engine::BlackScholes->new({bet => shift});
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
