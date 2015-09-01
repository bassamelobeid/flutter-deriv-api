package BOM::Product::Contract::Put;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

# Static methods
sub id              { return 20; }
sub code            { return 'PUT'; }
sub pricing_code    { return 'PUT'; }
sub category_code   { return 'callput'; }
sub display_name    { return 'lower'; }
sub sentiment       { return 'down'; }
sub other_side_code { return 'CALL'; }

sub localizable_description {
    return +{
        tick                  => '[_1] [_2] payout if [_3] after [plural,_5,%d tick,%d ticks] is strictly lower than [_6].',
        daily                 => '[_1] [_2] payout if [_3] is strictly lower than [_6] at [_5].',
        intraday              => '[_1] [_2] payout if [_3] is strictly lower than [_6] at [_5] after [_4].',
        intraday_fixed_expiry => '[_1] [_2] payout if [_3] is strictly lower than [_6] at [_5].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $value = ($self->exit_tick->quote < $self->barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
