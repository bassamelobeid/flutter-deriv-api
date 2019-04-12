package BOM::Product::Contract::Asiand;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary',
    'BOM::Product::Role::SingleBarrier' => {-excludes => ['_build_supplied_barrier', '_build_barrier']},
    'BOM::Product::Role::ExpireAtEnd', 'BOM::Product::Role::Asian';

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick and $self->barrier) {
        my $value = ($self->exit_tick->quote < $self->barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
