#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Deep;

use BOM::Platform::CryptoCashier::Payment::Error qw(create_error);

my %error_map          = %BOM::Platform::CryptoCashier::Payment::Error::ERROR_MAP;
my $unknown_error_code = 'UnknownError';

subtest 'create_error' => sub {
    my ($code, $param, $detail);
    my @tests = ({
            name            => 'Non-existent error code',
            params          => [$code = 'NON_EXISTENT_ERROR_CODE'],
            expected_result => {
                code    => $code,
                message => $error_map{$unknown_error_code},
            },
        },
        {
            name            => 'Simple error',
            params          => [$code = 'ZeroPaymentAmount'],
            expected_result => {
                code    => $code,
                message => $error_map{$code},
            },
        },
        {
            name            => 'Error having placeholder',
            params          => [$code = 'ClientNotFound', message_params => [$param = 'client_loginid']],
            expected_result => {
                code    => $code,
                message => sprintf($error_map{$code}, $param),
            },
        },
        {
            name            => 'Error having placeholder handles non-array too',
            params          => [$code = 'ClientNotFound', message_params => $param],
            expected_result => {
                code    => $code,
                message => sprintf($error_map{$code}, $param),
            },
        },
    );

    for my $test (@tests) {
        cmp_deeply create_error($test->{params}->@*), $test->{expected_result}, "Returns expected result for: '$test->{name}'.";
    }
};

done_testing;
