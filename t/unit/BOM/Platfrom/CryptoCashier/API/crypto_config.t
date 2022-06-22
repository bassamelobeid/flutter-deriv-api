#!/usr/bin/env perl

use strict;
use warnings;
no indirect;
use Test::More;
use Test::MockModule;

use BOM::Platform::CryptoCashier::API;

my $mock_crypto_api = Test::MockModule->new('BOM::Platform::CryptoCashier::API');
my $expected_result = {
    currencies_config => {
        BTC => {
            minimum_withdrawal => 0.1,
        },
    },
};
$mock_crypto_api->mock(
    _request => sub {
        return $expected_result;
    },
);

subtest 'crypto_config' => sub {
    my $crypto_service = BOM::Platform::CryptoCashier::API->new();
    my $crypto_config  = $crypto_service->crypto_config("BTC");
    is_deeply $crypto_config, $expected_result, "Correct result from crypto_config api handler";
    $mock_crypto_api->unmock_all();
};
done_testing;
