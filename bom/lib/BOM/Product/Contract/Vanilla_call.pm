package BOM::Product::Contract::Vanilla_call;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Vanilla', 'BOM::Product::Role::SingleBarrier';

use BOM::Product::Pricing::Engine::BlackScholes;
use BOM::Product::Exception;

sub ticks_to_expiry {
    my $self = shift;

    return BOM::Product::Exception->throw(
        error_code => 'InvalidTickExpiry',
        error_args => [$self->code],
        details    => {field => 'duration'},
    );
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
