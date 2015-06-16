package BOM::Product::Contract::Onetouch;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::AmericanExpiry';

sub id              { return 130; }
sub code            { return 'ONETOUCH'; }
sub pricing_code    { return 'ONETOUCH'; }
sub category_code   { return 'touchnotouch'; }
sub display_name    { return 'touches'; }
sub sentiment       { return 'high_vol'; }
sub other_side_code { return 'NOTOUCH'; }
sub payouttime      { return 'hit'; }

sub localizable_description {
    return +{
        daily                 => '[_1] <strong>[_2]</strong> payout if [_3] <strong>touches [_6]</strong> through [_5].',
        intraday              => '[_1] <strong>[_2]</strong> payout if [_3] <strong>touches [_6]</strong> through [_5] after [_4].',
        intraday_fixed_expiry => '[_1] <strong>[_2]</strong> payout if [_3] <strong>touches [_6]</strong> through [_5].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    my ($high, $low) = $self->get_high_low_for_contract_period();
    my $expired = $self->is_after_expiry;
    if (defined $high and defined $low) {
        my $barrier = $self->barrier->as_absolute;
        my $value   = 0;
        if ($high >= $barrier && $low <= $barrier) {
            $value   = $self->payout;
            $expired = 1;
        } elsif ($expired) {
            $value = 0;
        }
        $self->value($value);
    }

    return $expired;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
