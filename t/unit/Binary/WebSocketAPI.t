use strict;
use warnings;
use Test::More;
use Test::MockModule;

use Binary::WebSocketAPI;
use JSON::MaybeXS;
use List::Util qw( first any none);

my $json = JSON::MaybeXS->new;

my $mock_websocketAPI                   = Test::MockModule->new('Binary::WebSocketAPI');
my $mock_apps_blocked_from_domain_redis = '{}';
$mock_websocketAPI->mock(
    'set_to_redis_master',
    sub {
        my ($key, $value) = @_;
        $mock_apps_blocked_from_domain_redis = $value;
    });

$mock_websocketAPI->mock(
    'get_from_redis_master',
    sub {
        my ($key) = @_;
        return $mock_apps_blocked_from_domain_redis;
    });

subtest check_blocked_app_id => sub {

    my $test_app_id = 2;
    Binary::WebSocketAPI::add_remove_apps_blocked_from_opertion_domain('add', $test_app_id, 'blue');
    my $apps_blocked_from_operation_domain = Binary::WebSocketAPI::get_apps_blocked_from_operation_domain();

    my $result = any { $test_app_id eq $_ } $apps_blocked_from_operation_domain->{blue}->@*;
    is($result, 1, "Blocked APP ID $test_app_id");

    Binary::WebSocketAPI::add_remove_apps_blocked_from_opertion_domain('del', $test_app_id, 'blue');
    $apps_blocked_from_operation_domain = Binary::WebSocketAPI::get_apps_blocked_from_operation_domain();
    $result                             = none { $test_app_id eq $_ } $apps_blocked_from_operation_domain->{blue}->@*;
    is($result, 1, "Unblocked APP ID $test_app_id");
};

done_testing;
