#!/usr/bin/env perl

use strict;
use warnings;
no indirect;
use Test::More;
use Test::MockModule;

use BOM::Platform::CryptoCashier::API;

my $mock_crypto_api = Test::MockModule->new('BOM::Platform::CryptoCashier::API');

my $expected_result = {
    BTC => {
        withdrawal_fee => {
            value       => 0.0001,
            expiry_time => 1689305114,
            unique_id   => "c84a793b-8a87-7999-ce10-9b22f7ceead3",
        },
    },
};
$mock_crypto_api->mock(
    _request => sub {
        return $expected_result;
    },
);

subtest 'crypto_estimations' => sub {
    my $crypto_service     = BOM::Platform::CryptoCashier::API->new();
    my $crypto_estimations = $crypto_service->crypto_estimations("BTC");
    is_deeply $crypto_estimations, $expected_result, "Correct result from crypto_estimations api handler";
    $mock_crypto_api->unmock_all();
};
done_testing;
