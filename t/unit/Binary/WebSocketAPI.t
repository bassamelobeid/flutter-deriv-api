use strict;
use warnings;
use Test::More;
use Test::MockModule;

use Binary::WebSocketAPI;
use List::Util qw( first any none);

subtest check_blocked_app_id => sub {

    my $test_app_id = 2;
    Binary::WebSocketAPI::add_remove_apps_blocked_from_opertion_domain('add', $test_app_id, 'blue')->get;
    my $apps_blocked_from_operation_domain = Binary::WebSocketAPI::get_apps_blocked_from_operation_domain()->get;
    my $result                             = any { $test_app_id eq $_ } $apps_blocked_from_operation_domain->{blue}->@*;
    is($result, 1, "Blocked APP ID $test_app_id");

    Binary::WebSocketAPI::add_remove_apps_blocked_from_opertion_domain('del', $test_app_id, 'blue')->get;
    $apps_blocked_from_operation_domain = Binary::WebSocketAPI::get_apps_blocked_from_operation_domain()->get;
    $result                             = none { $test_app_id eq $_ } $apps_blocked_from_operation_domain->{blue}->@*;
    is($result, 1, "Unblocked APP ID $test_app_id");
};

done_testing;
