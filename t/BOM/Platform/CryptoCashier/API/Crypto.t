#!/usr/bin/env perl

use strict;
use warnings;
no indirect;

use BOM::Platform::CryptoCashier::API;
use BOM::Config;

use HTTP::Response;
use HTTP::Request;

use Test::More;
use Test::MockModule;

my $mock_dd              = Test::MockModule->new('DataDog::DogStatsd::Helper');
my $mock_crypto_api      = Test::MockModule->new('BOM::Platform::CryptoCashier::API');
my $mock_user_agent      = Test::MockModule->new('LWP::UserAgent');
my $mock_currency_config = Test::MockModule->new('BOM::Config::CurrencyConfig');

subtest "_request" => sub {

    # generate possible cases
    my $cases = [{
            endpoint    => "deposit",
            app_id      => 16303,
            http_status => 200,
            brand       => "deriv"
        },
        {
            endpoint    => "deposit",
            app_id      => 123,
            http_status => 200,
            brand       => "some client"
        },
        {
            endpoint    => "deposit",
            app_id      => 16303,
            http_status => 400,
            brand       => "deriv"
        },
        {
            endpoint    => "withdraw",
            app_id      => 16303,
            http_status => 200,
            brand       => "deriv",
            dry_run     => 1,
            method      => 'post'
        },
        {
            endpoint    => "withdraw",
            app_id      => 16303,
            http_status => 500,
            brand       => "deriv",
            dry_run     => 1,
            method      => 'post'
        }];

    foreach my $case (@$cases) {
        my $endpoint    = $case->{endpoint};
        my $app_id      = $case->{app_id};
        my $brand       = $case->{brand};
        my $http_status = $case->{http_status};
        my $dry_run     = $case->{dry_run} // 0;
        my $method      = $case->{method}  // 'get';
        my $status      = $http_status == 200 ? "success" : "fail";
        my $uri         = "http://localhost:5055/api/v1/$endpoint?loginid=&app_id=$app_id&brand=$brand&domain=&&&source=16303";

        my $query_params = {
            loginid       => 'CR90000001',
            app_id        => $app_id,
            brand         => $brand,
            domain        => 'deriv.com',
            l             => 'EN',
            language      => 'EN',
            source        => 16303,
            currency_code => 'ETH',
        };

        my $payload = {
            loginid       => 'CR90000001',
            address       => 'address',
            amount        => 123,
            dry_run       => $dry_run,
            currency_code => 'ETH',
        };

        setup_dd_mock({
            endpoint      => $endpoint,
            status        => $status,
            app_id        => $app_id,
            origin        => $brand,
            dry_run       => $dry_run,
            currency_code => 'ETH',
        });

        $mock_crypto_api->mock(
            decode_json_utf8 => sub {
                return {};
            });

        $mock_user_agent->mock(
            get => sub {
                my $http_response = HTTP::Response->new($http_status);
                $http_response->content(handle_error_code_content($http_status))
                    if $http_status != 200;
                my $request = HTTP::Request->new(GET => $uri);
                $http_response->request($request);

                return $http_response;
            },
            post => sub {
                my $http_response = HTTP::Response->new($http_status);
                $http_response->content(handle_error_code_content($http_status))
                    if $http_status != 200;
                my $request = HTTP::Request->new(POST => $uri);
                $http_response->request($request);

                return $http_response;
            });

        my $request_data = {
            method   => $method,
            endpoint => $endpoint,
            ($method eq 'get' ? (query_params => $query_params) : (payload => $payload))};

        my $crypto_service = BOM::Platform::CryptoCashier::API->new({});
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

# This test needs to be removed while we clean up handling the switching of crypto api host through backoffice.
subtest "config" => sub {
    my $crypto_service = BOM::Platform::CryptoCashier::API->new({});
    my $revert_adddress;
    $mock_currency_config->mock(
        get_revert_host_address => sub {
            return $revert_adddress;
        });

    $revert_adddress = "";
    my $config = $crypto_service->config;
    is $config->{host}, 'http://localhost', 'Correct host when revert address is empty string';
    is $config->{port}, 5055,               'Correct port when revert address is empty string';

    $revert_adddress = 'https://crypto-cashier-api.deriv.com';
    $config          = $crypto_service->config;
    is $config->{host}, $revert_adddress, 'Correct host when revert address is set';
    is $config->{port}, 5055,             'Correct port when revert address is set';

    $revert_adddress = "";
    $config          = $crypto_service->config;
    is $config->{host}, 'http://localhost', 'Correct host when revert address is set back to empty string';
    is $config->{port}, 5055,               'Correct port when revert address is set back to empty string';
};

sub setup_dd_mock {
    my $params = shift;
    my ($endpoint, $status, $app_id, $origin, $is_dry_run, $currency_code) = @$params{qw/endpoint status app_id origin is_dry_run currency_code/};
    $is_dry_run //= 0;

    $mock_dd->unmock_all;

    $mock_dd->mock(
        stats_inc => sub {
            my ($metric_name, $params) = @_;
            my $tags = $params->{tags};

            is $metric_name, BOM::Platform::CryptoCashier::API::DD_API_CALL_RESULT_KEY, 'Correct DD metric name';
            is_deeply $tags, ["status:$status", "endpoint:$endpoint", "currency_code:$currency_code"], 'Correct tags for the DD metric';
        });
}

sub handle_error_code_content {
    my $error_code = shift;

    if ($error_code == 500) {
        return "Internal Server Error";
    } elsif ($error_code == 400) {
        return "Bad request";
    }
}

done_testing;
