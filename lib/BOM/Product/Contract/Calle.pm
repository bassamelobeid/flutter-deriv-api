package BOM::Product::Contract::Calle;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

# Static methods

sub id              { return 290; }
sub code            { return 'CALLE'; }
sub pricing_code    { return 'CALL'; }
sub category_code   { return 'callput'; }
sub display_name    { return 'higher'; }
sub sentiment       { return 'up'; }
sub other_side_code { return 'PUTE'; }

sub localizable_description {
    return +{
        tick                  => '[_1] [_2] payout if [_3] after [plural,_5,%d tick,%d ticks] is higher than or equal to [_6].',
        daily                 => '[_1] [_2] payout if [_3] is higher than or equal to [_6] at [_5].',
        intraday              => '[_1] [_2] payout if [_3] is higher than or equal to [_6] at [_5] after [_4].',
        intraday_fixed_expiry => '[_1] [_2] payout if [_3] is higher than or equal to [_6] at [_5].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $value = ($self->exit_tick->quote >= $self->barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
