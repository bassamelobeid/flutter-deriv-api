#!/usr/bin/env perl

use strict;
use warnings;
no indirect;

use BOM::RPC::v3::Services::Crypto;

use HTTP::Response;
use HTTP::Request;

use Test::More;
use Test::MockModule;

my $mock_dd         = Test::MockModule->new('DataDog::DogStatsd::Helper');
my $mock_crypto     = Test::MockModule->new('BOM::RPC::v3::Services::Crypto');
my $mock_user_agent = Test::MockModule->new('LWP::UserAgent');

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
        my $uri =
            "http://localhost:5055/api/v1/$endpoint?loginid=CR90000001&app_id=$app_id&brand=$brand&domain=deriv.com&l=EN&language=EN&source=16303";

        setup_dd_mock({
            endpoint => $endpoint,
            status   => $status,
            app_id   => $app_id,
            origin   => $brand,
            dry_run  => $dry_run
        });

        $mock_crypto->mock(
            decode_json_utf8 => sub {
                return {};
            });

        $mock_user_agent->mock(
            get => sub {
                my $http_response = HTTP::Response->new($http_status);
                my $request       = HTTP::Request->new(GET => $uri);
                $http_response->request($request);

                return $http_response;
            },
            post => sub {
                my $http_response = HTTP::Response->new($http_status);
                my $request       = HTTP::Request->new(POST => $uri);
                $http_response->request($request);

                return $http_response;
            });

        my $crypto_service = BOM::RPC::v3::Services::Crypto->new({});
        my $result         = $crypto_service->_request($method => $uri);

        $mock_crypto->unmock_all();
        $mock_dd->unmock_all();
    }
};

sub setup_dd_mock {
    my $params = shift;
    my ($endpoint, $status, $app_id, $origin, $is_dry_run) = @$params{qw/endpoint status app_id origin is_dry_run/};
    $is_dry_run //= 0;

    $mock_dd->unmock_all;

    $mock_dd->mock(
        stats_inc => sub {
            my ($metric_name, $params) = @_;
            my $tags = $params->{tags};

            is $metric_name, BOM::RPC::v3::Services::Crypto::DD_API_CALL_RESULT_KEY, 'Correct DD metric name';
            is_deeply $tags, ["status:$status"], 'Correct tags for the DD metric';
        });
}

done_testing;
