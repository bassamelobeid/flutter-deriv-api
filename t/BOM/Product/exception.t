#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use BOM::Product::Exception;

subtest 'general' => sub {
    throws_ok { BOM::Product::Exception->throw(error_code => 'Unknown') } qr/Unknown error_code/, 'throws exception if error_code is invalid';
    throws_ok { BOM::Product::Exception->throw() } qr/Missing required arguments: error_code/, 'throws exception if error_code is undef';
    dies_ok { BOM::Product::Exception->throw(error_code => 'MissingRequiredIBetType') }
    'throws exception if error_args is not provided when it is required';
    dies_ok {
        my $exp = BOM::Product::Exception->throw(error_code => 'AlreadyExpired');
        is $exp->message_to_client->[0], 'Missing required contract parameters. ([_1])', 'message to client is correct';
        is $exp->message_to_client->[1], 'me',                                           'error_args is correct';
    }
    'dies with proper exception object';
};

done_testing();
