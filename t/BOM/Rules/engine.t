use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;
use BOM::Rules::Registry qw(register_action rule);
use BOM::Rules::Registry::Action;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

subtest 'Context initialization' => sub {
    my $rule_engine = BOM::Rules::Engine->new(
        client          => $client,
        stop_on_failure => 0
    );
    is_deeply $rule_engine->context,
        {
        client          => $client,
        loginid         => $client->loginid,
        landing_company => $client->landing_company->short,
        residence       => $client->residence,
        stop_on_failure => 0
        },
        'Context loginid and landing_company matches that of client';

    $rule_engine = BOM::Rules::Engine->new(loginid => $client->loginid);
    is_deeply $rule_engine->context,
        {
        client          => $client,
        loginid         => $client->loginid,
        landing_company => $client->landing_company->short,
        residence       => $client->residence,
        stop_on_failure => 1
        },
        'Context client and landing_company matches that of loginid';

    $rule_engine = BOM::Rules::Engine->new(
        client          => $client,
        loginid         => 'test_loginid',
        landing_company => 'test_lc',
        residence       => 'xyz',
        stop_on_failure => 1
    );
    is_deeply $rule_engine->context,
        {
        client          => $client,
        loginid         => 'test_loginid',
        landing_company => 'test_lc',
        residence       => 'xyz',
        stop_on_failure => 1,
        },
        'Context loginid, landing_company and residence are overriden by constructor args';
};

subtest 'Verify an action' => sub {
    my $rule_engine_1 = BOM::Rules::Engine->new(client => $client);
    like exception { $rule_engine_1->verify_action() }, qr/Action name is required/, 'exception thrown on verify without providing action';
    like exception { $rule_engine_1->verify_action('invalid_name_for_testing') }, qr/Unknown action 'invalid_name_for_testing' cannot be verified/,
        'exception thrown on invalid name for testing';

    my @action_verify_args;
    my $mock_action = Test::MockModule->new('BOM::Rules::Registry::Action');
    $mock_action->redefine(verify => sub { @action_verify_args = @_; return $mock_action->original('verify')->(@_); });

    my $test_action = BOM::Rules::Registry::Action->new(
        name     => 'test_action',
        rule_set => []);
    my $mock_registry = Test::MockModule->new('BOM::Rules::Registry');
    $mock_registry->redefine('get_action' => sub { return $test_action });

    ok $rule_engine_1->verify_action('test_action'), 'action result is as expected';
    is scalar @action_verify_args, 3, 'Number of args is correct';
    my ($action, $context, $args) = @action_verify_args;
    is $action, $test_action, 'Correct action is sought';
    is $context, $rule_engine_1->context, 'Action verification is trggered with correct context';
    is_deeply $args, {}, 'Action is verified with empty args';

    undef @action_verify_args;
    isa_ok $rule_engine_1->verify_action(
        'test_action',
        {
            a => 1,
            b => 2,
        }
        ),
        'BOM::Rules::Result', 'action result is as expected';
    is scalar @action_verify_args, 3, 'Number of args is correct';
    ($action, $context, $args) = @action_verify_args;
    is $action, $test_action, 'Correct action is sought';
    is $context, $rule_engine_1->context, 'Action verification is trggered with correct context';
    is_deeply $args,
        {
        a => 1,
        b => 2
        },
        'Action is verified with empty args';

    $mock_registry->unmock_all;
    $mock_action->unmock_all;
};

subtest 'Applying rules' => sub {
    my $rule_engine_1 = BOM::Rules::Engine->new(client => $client);
    like exception { $rule_engine_1->apply_rules() }, qr/Rule name cannot be empty/, 'Correct exception for empty rule name';
    like exception { $rule_engine_1->apply_rules('invalid_name_for_testing') }, qr/Unknown rule 'invalid_name_for_testing' cannot be applied/,
        'Correct error for invalid rule name';

    is_deeply $rule_engine_1->apply_rules([]),
        {
        has_failure  => 0,
        failed_rules => {},
        errors       => {},
        passed_rules => []
        },
        'Empty rule array is accepted';

    my $test_rule = rule 'test rule 1' => {
        code => sub { return 'result 1' }
    };

    is_deeply $rule_engine_1->apply_rules('test rule 1'),
        {
        has_failure  => 0,
        failed_rules => {},
        errors       => {},
        passed_rules => ['test rule 1']
        },
        'Rule is applied with default return value';
    is_deeply $rule_engine_1->apply_rules(['test rule 1']),
        {
        has_failure  => 0,
        failed_rules => {},
        errors       => {},
        passed_rules => ['test rule 1']
        },
        'Rule array is applied with default return value';

    my @rule_args;
    my $mock_rule = Test::MockModule->new('BOM::Rules::Registry::Rule');
    $mock_rule->redefine(apply => sub { @rule_args = @_; return $mock_rule->original('apply')->(@_); });

    is $rule_engine_1->apply_rules(
        'test rule 1',
        {
            a => 1,
            b => 2,
        })->{has_failure}, 0, 'Rule applied';
    is scalar @rule_args, 3, 'Number of args is correct';
    my ($rule, $context, $args) = @rule_args;
    is $rule, $test_rule, 'Correct rule is found';
    is $context, $rule_engine_1->context, 'Rule context is correct';
    is_deeply $args,
        {
        a => 1,
        b => 2
        },
        'Rule args are correct';

    $mock_rule->unmock_all;

    rule 'failing rule' => {
        code => sub { die {code => 'DummyError'} }
    };
    rule 'failing rule2' => {
        code => sub { die {code => 'DummyError2'} }
    };

    is_deeply exception { $rule_engine_1->apply_rules('failing rule') }, {code => 'DummyError'}, 'Correct exception for the failing rule';

    my $rule_engine_2 = BOM::Rules::Engine->new(
        client          => $client,
        stop_on_failure => 0
    );

    is_deeply $rule_engine_2->apply_rules('failing rule'),
        {
        has_failure  => 1,
        failed_rules => {'failing rule' => {code => 'DummyError'}},
        errors       => {DummyError     => 1},
        passed_rules => []
        },
        'Correct result for a failing rule';

    is_deeply $rule_engine_2->apply_rules(['failing rule', 'test rule 1', 'failing rule2']),
        {
        has_failure  => 1,
        failed_rules => {
            'failing rule'  => {code => 'DummyError'},
            'failing rule2' => {code => 'DummyError2'}
        },
        errors => {
            DummyError  => 1,
            DummyError2 => 1
        },
        passed_rules => ['test rule 1']
        },
        'Correct result for three rules (two failing and one passing)';
};

done_testing();
