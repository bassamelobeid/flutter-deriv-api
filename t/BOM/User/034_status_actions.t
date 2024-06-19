use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Warn;
use Date::Utility;
use Test::MockModule;

use BOM::User::Client::StatusActions;

subtest 'Single action' => sub {

    my $count = 0;

    my $mock = Test::MockModule->new('BOM::User::Client::StatusActions');

    my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');

    $mock_emitter->redefine(
        'emit',
        sub {
            $count++;
        });

    $mock->redefine(
        '_get_action_config',
        sub {
            return [{
                    name         => 'test_action',
                    default_args => ['client_loginid']}];
        });

    BOM::User::Client::StatusActions->trigger('test_loginid', 'test_status_code');

    ok $count == 1, 'Action is triggered';

    $mock->unmock_all;
    $mock_emitter->unmock_all;

};

subtest 'Multiple Actions' => sub {

    my %count = (
        test_action_1 => 0,
        test_action_2 => 0
    );

    my $mock = Test::MockModule->new('BOM::User::Client::StatusActions');

    my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');

    $mock_emitter->redefine(
        'emit',
        sub {
            my $event_name = shift;
            $count{$event_name}++;
        });

    $mock->redefine(
        '_get_action_config',
        sub {
            return [{
                    name         => 'test_action_1',
                    default_args => ['client_loginid']
                },
                {
                    name         => 'test_action_2',
                    default_args => ['client_loginid']}];
        });

    BOM::User::Client::StatusActions->trigger('test_loginid', 'test_status_code');

    ok $count{test_action_1} == 1, 'Action 1 is triggered';
    ok $count{test_action_2} == 1, 'Action 2 is triggered';

    $mock->unmock_all;
    $mock_emitter->unmock_all;

};

subtest 'No Actions' => sub {

    my $count = 0;

    my $mock = Test::MockModule->new('BOM::User::Client::StatusActions');

    my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');

    $mock_emitter->redefine(
        'emit',
        sub {
            $count++;
        });

    $mock->redefine(
        '_get_action_config',
        sub {
            return [];
        });

    BOM::User::Client::StatusActions->trigger('test_loginid', 'test_status_code');

    ok $count == 0, 'No actions are triggered';

    $mock->unmock_all;
    $mock_emitter->unmock_all;

};

subtest 'Default args' => sub {

    my $args;

    my $mock = Test::MockModule->new('BOM::User::Client::StatusActions');

    my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');

    $mock_emitter->redefine(
        'emit',
        sub {
            my $event_name = shift;
            $args = shift;
        });

    $mock->redefine(
        '_get_action_config',
        sub {
            return [{
                    name         => 'test_action',
                    default_args => ['client_loginid', 'test_arg']}];
        });

    BOM::User::Client::StatusActions->trigger('test_loginid', 'test_status_code', {test_arg => 'test_value'});

    cmp_deeply $args,
        {
        loginid  => 'test_loginid',
        test_arg => 'test_value'
        },
        'Default args are passed';

    $mock->unmock_all;
    $mock_emitter->unmock_all;

};

subtest 'Additional args' => sub {

    my $args;

    my $mock = Test::MockModule->new('BOM::User::Client::StatusActions');

    my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');

    $mock_emitter->redefine(
        'emit',
        sub {
            my $event_name = shift;
            $args = shift;
        });

    $mock->redefine(
        '_get_action_config',
        sub {
            return [{
                    name         => 'test_action',
                    default_args => ['client_loginid']}];
        });

    BOM::User::Client::StatusActions->trigger('test_loginid', 'test_status_code', {test_arg => 'test_value'});

    cmp_deeply $args,
        {
        loginid  => 'test_loginid',
        test_arg => 'test_value'
        },
        'Additional args are passed';

    $mock->unmock_all;
    $mock_emitter->unmock_all;

};

subtest 'Default args - bulk trigger' => sub {

    my $args = [];

    my $mock = Test::MockModule->new('BOM::User::Client::StatusActions');

    my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');

    $mock_emitter->redefine(
        'emit',
        sub {
            my $event_name = shift;
            push @$args, shift;
        });

    $mock->redefine(
        '_get_action_config',
        sub {
            return [{
                    name         => 'test_action',
                    default_args => ['client_loginid', 'test_arg']}];
        });

    BOM::User::Client::StatusActions->trigger_bulk(['test_loginid', 'test_loginid2'], 'test_status_code', {test_arg => 'test_value'});

    cmp_deeply $args,
        [{
            loginid  => 'test_loginid',
            test_arg => 'test_value'
        },
        {
            loginid  => 'test_loginid2',
            test_arg => 'test_value'
        },
        ],
        'Default args are passed';

    $mock->unmock_all;
    $mock_emitter->unmock_all;

};

done_testing();
