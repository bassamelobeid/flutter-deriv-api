use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Deep;
use Test::Exception;
use Test::Fatal;
use Test::MockModule;
use Test::MemoryGrowth;

use DataDog::DogStatsd::Helper;
use Net::Async::HTTP;
use Time::Moment;
use Future;
use HTTP::Response;
use HTTP::Headers;

use BOM::MT5::User::Async;
use BOM::Config;
use BOM::Config::Runtime;

my $mock_config  = Test::MockModule->new('BOM::Config');
my $mock_http    = Test::MockModule->new('Net::Async::HTTP');
my $mocked_async = Test::MockModule->new('BOM::MT5::User::Async');

$mock_config->mock(
    'mt5_webapi_config',
    sub {
        return {
            mt5_http_proxy_url => 'http://daproxy/',
        };
    });

my $key_timing;
my $key_inc;
my $value;
my $tags;

$mocked_async->mock(
    '_is_http_proxy_enabled_for',
    sub {
        return 1;
    });

$mocked_async->mock(
    '_is_parallel_run_enabled',
    sub {
        return 0;
    });

$mock_http->mock(
    'POST',
    sub {
        my $headers  = HTTP::Headers->new('Content-Type', 'application/json');
        my $response = HTTP::Response->new(200, 'Dummy', $headers, '{"result":"OK"}');
        return Future->done($response);
    });

my $cmd      = 'UserAdd';
my $srv_type = 'demo';
my $srv_key  = 'p01_ts01';

subtest 'MT5 HTTP Proxy Call memory check' => sub {
    $mock_http->mock(
        'POST',
        sub {
            my $headers  = HTTP::Headers->new('Content-Type', 'application/json');
            my $response = HTTP::Response->new(200, 'Dummy', $headers, '{"result":"OK"}');
            return Future->done($response);
        });
    my $param = {param => 'something'};

    no_growth {
        BOM::MT5::User::Async::_invoke($cmd, $srv_type, $srv_key, 'MTD', $param)->get();
    }
    'MT5 HTTP Proxy Call does not increase memory';

};

$mock_config->unmock_all;
$mocked_async->unmock_all;
$mock_http->unmock_all;

done_testing;
