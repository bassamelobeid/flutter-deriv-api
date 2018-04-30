package BOM::Test::Helper::CTC;

use strict;
use warnings;
no warnings qw/redefine/;

use BOM::CTC::Helper;

BEGIN {
    *BOM::CTC::Helper::currency_code = sub {
        my ($self) = @_;

        my $currency_code = $self->client->default_account->currency_code;
        return $currency_code;
    };
};

1;
