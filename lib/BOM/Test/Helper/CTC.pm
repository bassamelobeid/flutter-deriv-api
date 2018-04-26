package BOM::Test::Helper::CTC;   

use strict;
use warnings;

use Moose;
extends 'BOM::CTC::Helper';

sub currency_code {
    my ($self) = @_;

    my $currency_code = $self->client->default_account->currency_code;
    return $currency_code;
}

