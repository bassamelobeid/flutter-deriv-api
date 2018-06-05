package BOM::Backoffice::Script::ValidateStaffPaymentLimit;

use warnings;
use strict;

use BOM::Config::Runtime;
use JSON::MaybeXS;
use Scalar::Util qw(looks_like_number);

sub validate {
    my $staff  = shift;
    my $amount = shift;

    my $payment_limits = JSON::MaybeXS->new->decode(BOM::Config::Runtime->instance->app_config->payments->payment_limits);
    if ($payment_limits->{$staff} and looks_like_number($payment_limits->{$staff})) {
        if ($amount > $payment_limits->{$staff}) {
            return Error::Base->cuss(
                -type => 'AmountGreaterThanLimit',
                -mesg => 'The amount is larger than authorization limit for staff',
            );
        }
    } else {
        return Error::Base->cuss(
            -type => 'NoPaymentLimitForUser',
            -mesg => 'There is no payment limit configured in the backoffice payment_limits for this user',
        );
    }
    return;
}

1;
