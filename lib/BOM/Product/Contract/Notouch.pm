package BOM::Product::Contract::Notouch;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::AmericanExpiry';

sub id              { return 140; }
sub code            { return 'NOTOUCH'; }
sub pricing_code    { return 'NOTOUCH'; }
sub display_name    { return 'does not touch'; }
sub category_code   { return 'touchnotouch'; }
sub sentiment       { return 'low_vol'; }
sub other_side_code { return 'ONETOUCH'; }

sub localizable_description {
    return +{
        daily                 => '[_1] [_2] payout if [_3] does not touch [_6] through [_5].',
        intraday              => '[_1] [_2] payout if [_3] does not touch [_6] through [_5] after [_4].',
        intraday_fixed_expiry => '[_1] [_2] payout if [_3] does not touch [_6] through [_5].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    my $expired = $self->is_after_expiry and $self->exit_tick;    # Tick validation is in contract validation
    my ($high, $low) = $self->get_high_low_for_contract_period();
    if (defined $high and defined $low) {
        my $barrier = $self->barrier->as_absolute;
        my $value   = 0;
        if ($high >= $barrier && $low <= $barrier) {
            $value   = 0;
            $expired = 1;
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
