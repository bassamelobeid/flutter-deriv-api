use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Deep;
use Test::Exception;
use Test::Fatal;
use Test::MockModule;

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
my $mock_http    = Test::MockModule->new('HTTP::Tiny');
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
    'stats_timing',
    sub {
        $key_timing = shift;
        $value      = shift;
        $tags       = shift;
    });

$mocked_async->mock(
    'stats_inc',
    sub {
        $key_inc = shift;
        $tags    = shift;
    });

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
    'post',
    sub {

        my $response = {content => '{"user":{"login":40013070,"language":0}}'};
        return $response;
    });

my $cmd                  = 'UserAdd';
my $srv_type             = 'demo';
my $srv_key              = 'p01_ts01';
my $http_status_category = 'unknown';

subtest 'Sending http proxy timing to DataDog' => sub {
    my $param = {param => 'something'};

    my $res = BOM::MT5::User::Async::_invoke($cmd, $srv_type, $srv_key, 'MTD', $param)->get();

    is($key_timing, 'mt5.call.proxy.timing', 'The key for timing mt5 http proxy call is correct');
    ok($value, 'A value for the timing is sent');
    is_deeply($tags, {tags => ["mt5:$cmd", "server_type:$srv_type", "server_code:$srv_key"]}, 'Expected tags received');
};

subtest 'Sending http proxy successful count to DataDog' => sub {
    $mock_http->mock(
        'POST',
        sub {
            my $headers  = HTTP::Headers->new('Content-Type', 'application/json');
            my $response = HTTP::Response->new(200, 'Dummy', $headers, '{"result":"OK"}');
            return Future->done($response);
        });
    my $param = {param => 'something'};

    my $res = BOM::MT5::User::Async::_invoke($cmd, $srv_type, $srv_key, 'MTD', $param)->get();

    is($key_inc, 'mt5.call.proxy.successful', 'The key for timing mt5 http proxy call is correct');
    ok($value, 'A value for the call is sent');
    is_deeply($tags, {tags => ["mt5:$cmd", "server_type:$srv_type", "server_code:$srv_key"]}, 'Expected tags received');
};

subtest 'Sending http proxy error count to DataDog' => sub {
    $mock_http->mock(
        'post',
        sub {
            return 'Something unexpectedly wrong';
        });
    $key_inc = undef;
    $tags    = undef;

    exception { BOM::MT5::User::Async::_invoke($cmd, $srv_type, $srv_key, 'MTD', {})->get() };

    is($key_inc, 'mt5.call.proxy.request_error', 'The key for error mt5 http proxy call is correct');
    is_deeply(
        $tags,
        {tags => ["mt5:$cmd", "server_type:$srv_type", "server_code:$srv_key", "http_status_category:$http_status_category"]},
        'Tags received as expected'
    );
};

subtest 'php script sending timing stats' => sub {
    my $param = {'param' => 'something'};
    $mocked_async->mock(
        '_is_http_proxy_enabled_for',
        sub {
            return 0;
        });
    $key_timing = undef;
    $value      = undef;
    $tags       = undef;

    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_mt5_wrapper.pl');

    my $res = BOM::MT5::User::Async::_invoke('pass', $srv_type, $srv_key, 'MTD', $param)->get();

    is($key_timing, 'mt5.call.timing', 'The key for timing php script call is correct');
    ok($value, 'A value for the timing was sent');
    is_deeply($tags, {tags => ["mt5:pass", "server_type:$srv_type", "server_code:$srv_key"]}, 'Expected tags received');
};

subtest 'php script sending error stats' => sub {
    my $param = {should => 'fail'};
    $mocked_async->mock(
        '_is_http_proxy_enabled_for',
        sub {
            return 0;
        });
    $key_inc = undef;
    $tags    = undef;

    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_mt5_wrapper.pl');
    like(
        exception { my $res = BOM::MT5::User::Async::_invoke('fail', $srv_type, $srv_key, 'MTD', $param)->get() },
        qr/binary_mt5 exited non-zero status/,
        'Script is expected to fail'
    );

    is($key_inc, 'mt5.call.php_nonzero_status', 'The key for timing php script call is correct');
    is_deeply($tags, {tags => ["mt5:fail", "server_type:$srv_type", "server_code:$srv_key"]}, 'Expected tags received');
};

$mock_config->unmock_all;
$mocked_async->unmock_all;
$mock_http->unmock_all;

done_testing;
