package BOM::Product::Contract::Range;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::AmericanExpiry';

sub id              { return 150; }
sub code            { return 'RANGE'; }
sub pricing_code    { return 'RANGE'; }
sub category_code   { return 'staysinout'; }
sub display_name    { return 'stays between'; }
sub sentiment       { return 'low_vol'; }
sub other_side_code { return 'UPORDOWN'; }

sub localizable_description {
    return +{
        daily => '[_1] <strong>[_2]</strong> payout if [_3] <strong>stays between [_7]</strong> to <strong>[_6]</strong> through [_5].',
        intraday =>
            '[_1] <strong>[_2]</strong> payout if [_3] <strong>stays between [_7]</strong> and <strong>[_6]</strong> through [_5] after [_4].',
        intraday_fixed_expiry =>
            '[_1] <strong>[_2]</strong> payout if [_3] <strong>stays between [_7]</strong> to <strong>[_6]</strong> through [_5].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    my ($high, $low) = $self->get_high_low_for_contract_period();
    my $expired = $self->is_after_expiry;
    if (defined $high and defined $low) {
        my $value        = 0;
        my $high_barrier = $self->high_barrier->as_absolute;
        my $low_barrier  = $self->low_barrier->as_absolute;
        if (($high >= $high_barrier && $low <= $high_barrier) || ($high >= $low_barrier && $low <= $low_barrier)) {
            $expired = 1;
            $value   = 0;
        } elsif ($expired) {
            $value = $self->payout;
        }
        $self->value($value);
    }

    return $expired;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
