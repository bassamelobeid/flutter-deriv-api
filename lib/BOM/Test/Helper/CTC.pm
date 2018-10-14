package BOM::Test::Helper::CTC;

use strict;
use warnings;

use BOM::CTC::Helper;
use BOM::Platform::Client::CashierValidation;

BEGIN {
    *BOM::CTC::Helper::currency_code = sub {
        my ($self) = @_;

        my $currency_code = $self->client->default_account->currency_code;
        return $currency_code;
    };

    *BOM::Platform::Client::CashierValidation::is_crypto_currency_suspended = sub {
        return 0;
        }
}

1;
