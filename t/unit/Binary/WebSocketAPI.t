use strict;
use warnings;
use Test::More;
use Test::MockModule;

use Binary::WebSocketAPI;
use Binary::WebSocketAPI::BalanceConnections;

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

subtest check_balance_connections => sub {
    is Binary::WebSocketAPI::BalanceConnections::connection_count_class(), 'lt20', 'default connection_count_class';
    ok !Binary::WebSocketAPI::BalanceConnections::get_active_connections_count(), 'no active_connections_count';
};

subtest test_run_hooks_sync => sub {
    my $test_var1 = 0;
    my $test_var2 = 0;
    my $test_var3 = 0;
    my $ret       = Binary::WebSocketAPI::_run_hooks_sync(
        'testHooks',
        {},
        {
            'testHooks' => [
                sub { my ($a, $b, $c, $d) = @_; $test_var1 += $c + $d; return; },
                sub { my ($a, $b, $c, $d) = @_; $test_var2 += $c - $d; return; },
                sub { my ($a, $b, $c, $d) = @_; $test_var3 += $d - $c; return; },
            ]
        },
        3, 7
    );
    is $test_var1, 10;
    is $test_var2, -4;
    is $test_var3, 4;
};

subtest test_run_hooks_async => sub {
    my $test_var1 = 0;
    my $test_var2 = 0;
    my $test_var3 = 0;
    my $ret       = Binary::WebSocketAPI::_run_hooks_async(
        'testHooks',
        {},
        {
            'testHooks' => [
                sub { my ($a, $b, $c, $d) = @_; $test_var1 += $c + $d; return; },
                sub { my ($a, $b, $c, $d) = @_; $test_var2 += $c - $d; return; },
                sub { my ($a, $b, $c, $d) = @_; $test_var3 += $d - $c; return; },
            ]
        },
        3, 7
    );
    is $test_var1, 10;
    is $test_var2, -4;
    is $test_var3, 4;
};

done_testing;
