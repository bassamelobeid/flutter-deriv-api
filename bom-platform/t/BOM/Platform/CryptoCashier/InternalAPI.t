#!/usr/bin/env perl

use strict;
use warnings;
no indirect;

use BOM::Platform::CryptoCashier::InternalAPI;

use HTTP::Response;
use HTTP::Request;

use Test::More;
use Test::MockModule;

my $mock_dd         = Test::MockModule->new('DataDog::DogStatsd::Helper');
my $mock_crypto_api = Test::MockModule->new('BOM::Platform::CryptoCashier::InternalAPI');
my $mock_user_agent = Test::MockModule->new('LWP::UserAgent');

subtest "_request" => sub {

    # generate possible cases
    my $cases = [{
            endpoint    => "process_batch",
            http_status => 200,
            method      => 'post'
        },
        {
            endpoint    => "process_batch",
            http_status => 500,
            method      => 'post'
        },
        {
            endpoint    => "process_batch",
            http_status => 400,
            method      => 'post'
        },
    ];

    foreach my $case (@$cases) {
        my $endpoint    = $case->{endpoint};
        my $http_status = $case->{http_status} // 200;
        my $method      = $case->{method}      // 'get';
        my $status      = $http_status == 200 ? "success" : "fail";
        my $uri         = "http://localhost:5057/api/v1/$endpoint";

        my $payload = {
            requests => [
                id     => 1,
                action => 'address/validate',
            ],
        };

        $mock_dd->mock(
            stats_inc => sub {
                my ($metric_name, $params) = @_;
                my $tags = $params->{tags};

                is $metric_name, BOM::Platform::CryptoCashier::InternalAPI::DD_API_CALL_RESULT_KEY, 'Correct DD metric name';
                is_deeply $tags, ["status:$status", "endpoint:$endpoint"], 'Correct tags for the DD metric';
            });

        $mock_crypto_api->mock(
            decode_json_utf8 => sub {
                return {};
            });

        $mock_user_agent->mock(
            request => sub {
                my ($ua, $request) = @_;

                my $http_response = HTTP::Response->new($http_status);
                $http_response->content(handle_error_code_content($http_status))
                    if $http_status != 200;

                $http_response->request($request);

                return $http_response;
            },
        );

        my $request_data = {
            method   => $method,
            endpoint => $endpoint,
            ($method eq 'get' ? (query_params => {}) : (payload => $payload))};

        my $crypto_service = BOM::Platform::CryptoCashier::InternalAPI->new();
        my $result         = $crypto_service->_request($request_data);

        if ($result->{error}) {
            is $result->{error}->{message}, handle_error_code_content($http_status), "Correct content message for request error";
            is $result->{error}->{message_to_client}, 'An error occurred while processing your request. Please try again later.',
                "Correct errror mesage for client on request error";
            is $result->{error}->{code}, 'CryptoConnectionError', "Correct error code for request error";
        }

        $mock_crypto_api->unmock_all();
        $mock_dd->unmock_all();
    }
};

sub handle_error_code_content {
    my $error_code = shift;

    if ($error_code == 500) {
        return "Internal Server Error";
    } elsif ($error_code == 400) {
        return "Bad request";
    }
}

done_testing;
