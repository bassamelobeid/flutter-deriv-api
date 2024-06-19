use strict;
use warnings;

use Test::More;
use Test::MockObject;
use Test::Exception;
use Test::Deep;
use Log::Any::Test;
use Log::Any qw($log);
use JSON::MaybeXS;
use JSON::MaybeUTF8 qw(encode_json_utf8);

my $json = JSON::MaybeXS->new;

# Need to mock rand function to test rpc_throttling and has to be done before loading the module
my $rand_response = 100;

BEGIN {
    *CORE::GLOBAL::rand = sub { return $rand_response; };
}

use Binary::WebSocketAPI;
use Binary::WebSocketAPI::StubApp;

my $mock_app = Binary::WebSocketAPI::StubApp->new()->{app};

# Insert some key-value pairs into redis
my $redis = Binary::WebSocketAPI::ws_redis_master();

is($Binary::WebSocketAPI::RPC_THROTTLE->{throttle},      0, 'check throttle is off by default on init');
is(scalar @$Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION, 1, 'check timeout extensions is per default on init');
cmp_deeply(
    Binary::WebSocketAPI::RPC_TIMEOUT_DEFAULT,
    $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION->[0],
    'check timeout extension data is as per default'
);

$redis->del('rpc::throttle');
$redis->del('rpc::timeout_extension');
Binary::WebSocketAPI::startup($mock_app);

is($Binary::WebSocketAPI::RPC_THROTTLE->{throttle},      0, 'check throttle is still off after start and no keys present in redis');
is(scalar @$Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION, 1, 'check timeout extensions is per default after start and no keys present in redis');
cmp_deeply(
    Binary::WebSocketAPI::RPC_TIMEOUT_DEFAULT,
    $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION->[0],
    'check timeout extension data is as per default after start'
);

my $data = [{
        'category'   => 'test1',
        'rpc'        => "test1",
        'offset'     => 98,
        "percentage" => 78,
    },
    {
        'category'   => 'test2',
        'rpc'        => "test2",
        'offset'     => 54,
        "percentage" => 32,
    }];
$redis->set('rpc::throttle'          => 1234);
$redis->set('rpc::timeout_extension' => Encode::encode_utf8($json->encode($data)));
Binary::WebSocketAPI::startup($mock_app);

is($Binary::WebSocketAPI::RPC_THROTTLE->{throttle},      1234, 'check throttle is as set in redis after start');
is(scalar @$Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION, 2,    'check timeout extensions as set in redis after start');
cmp_deeply($data, $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION, 'check timeout extension data is as set in redis after start');

$redis->set('rpc::throttle' => 0);    # Turn off throttling incase this test is being run on a QA box as it is very confusing to leave it on

done_testing();
