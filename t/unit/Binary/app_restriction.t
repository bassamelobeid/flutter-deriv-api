use strict;
use warnings;
use Test::More;
use Binary::WebSocketAPI;
use Binary::WebSocketAPI::v3::Instance::Redis qw(ws_redis_master);
use Test::MockModule;

# Mock global variables
my $OFFICIAL_APPS_MOCK = [123, 23233, 5];

# Set the official app list in the Redis server
my $redis = ws_redis_master();
$redis->sadd('domain_based_apps::official', @$OFFICIAL_APPS_MOCK);

# Mock is_app_official method
my $mock_module = Test::MockModule->new('Binary::WebSocketAPI');
$mock_module->mock(
    'is_app_official',
    sub {
        my $app_id = shift;
        return 1 if !defined $OFFICIAL_APPS_MOCK || !@$OFFICIAL_APPS_MOCK;
        return scalar grep { $_ eq $app_id } @$OFFICIAL_APPS_MOCK;
    });

# Continue with the test cases...
my $CHEF_ENVIRONMENTS = ['red', 'purple'];

subtest 'check_blocked_app_id' => sub {
    my $app_id           = 23233;
    my $operation_domain = "green";
    my $error_response   = Binary::WebSocketAPI::check_app_restriction($app_id, $operation_domain, $CHEF_ENVIRONMENTS);
    is($error_response, 0, "App ID allowed for the operation domain");

    # Test Case 2: App ID is not in the blocked apps list, but not allowed for the operation domain
    $app_id           = 1234;
    $operation_domain = "blue";
    $error_response   = Binary::WebSocketAPI::check_app_restriction($app_id, $operation_domain, $CHEF_ENVIRONMENTS);
    is($error_response, 1, "App ID is not allowed for the operation domain");

    # Test Case 2: App ID is not in the blocked apps list, but allowed for the non-operation domain
    $app_id           = 1411;
    $operation_domain = "red";
    $error_response   = Binary::WebSocketAPI::check_app_restriction($app_id, $operation_domain, $CHEF_ENVIRONMENTS);
    is($error_response, 0, "App ID is allowed for the non-operation domain");
};

done_testing();

# Clean up: Remove the official app list from the Redis server
$redis->srem('domain_based_apps::official', @$OFFICIAL_APPS_MOCK);
