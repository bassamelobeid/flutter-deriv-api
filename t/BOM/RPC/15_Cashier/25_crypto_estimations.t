use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;
use Test::Most;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use JSON::MaybeXS   qw(decode_json);
use LWP::UserAgent;

use BOM::Config::Redis;
use BOM::Test::RPC::QueueClient;

my $rpc_ct;
my $mocked_call   = Test::MockModule->new('LWP::UserAgent');
my $currency_code = 'BTC';
my $redis_key     = "rpc::cryptocurrency::crypto_estimations::" . $currency_code;

subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

subtest 'api crypto_estimations' => sub {

    my $invalid_currency = "abcd";
    $rpc_ct->call_ok(
        'crypto_estimations',
        {
            language => 'EN',
            args     => {
                crypto_estimations => 1,
                currency_code      => $invalid_currency
            }}
    )->has_no_system_error->has_error->error_code_is("CryptoInvalidCurrency", "Correct error code when invalid currency code is provided")
        ->error_message_is("The provided currency $invalid_currency is not a valid cryptocurrency.",
        "Correct error message when invalid currency code is provided");

    my $redis_read = BOM::Config::Redis::redis_replicated_read();

    my $redis_result = $redis_read->get($redis_key);
    is undef, $redis_result, "should not have cache result prior any call to api.";

    my $api_response = {
        BTC => {
            withdrawal_fee => {
                value       => 0.0001,
                expiry_time => 1689305114,
                unique_id   => "c84a793b-8a87-7999-ce10-9b22f7ceead3",

            }
        },
    };
    my $http_response = HTTP::Response->new(200);
    $mocked_call->mock(get => sub { $http_response->content(encode_json_utf8($api_response)); $http_response; });

    my $result_api = $rpc_ct->call_ok(
        'crypto_estimations',
        {
            language => 'EN',
            args     => {
                crypto_estimations => 1,
                currency_code      => $currency_code
            }})->has_no_system_error->has_no_error->result;

    $redis_result = decode_json($redis_read->get($redis_key));

    my $common_expected_result = {
        stash => {
            valid_source               => 1,
            app_markup_percentage      => 0,
            source_bypass_verification => 0,
            source_type                => 'official',
        },
    };
    my $expected_result = {$common_expected_result->%*, $redis_result->%*};

    cmp_deeply $result_api, $expected_result, 'Result matches with redis result as expected.';

    $mocked_call->unmock_all;
};

done_testing;
