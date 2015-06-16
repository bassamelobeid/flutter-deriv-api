package BOM::Product::Contract::Expiryrange;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub id              { return 170; }
sub code            { return 'EXPIRYRANGE'; }
sub pricing_code    { return 'EXPIRYRANGE'; }
sub category_code   { return 'endsinout'; }
sub display_name    { return 'ends between'; }
sub sentiment       { return 'low_vol'; }
sub other_side_code { return 'EXPIRYMISS'; }

sub localizable_description {
    return +{
        daily => '[_1] <strong>[_2]</strong> payout if [_3] <strong>ends strictly between [_7]</strong> to <strong>[_6]</strong> at [_5].',
        intraday =>
            '[_1] <strong>[_2]</strong> payout if [_3] <strong>ends strictly between [_7]</strong> to <strong>[_6]</strong> at [_5] after [_4].',
        intraday_fixed_expiry =>
            '[_1] <strong>[_2]</strong> payout if [_3] <strong>ends strictly between [_7]</strong> to <strong>[_6]</strong> at [_5].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $exit_spot = $self->exit_tick->quote;
        my $value = ($exit_spot < $self->high_barrier->as_absolute and $exit_spot > $self->low_barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
