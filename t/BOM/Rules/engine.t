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
    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    is_deeply $rule_engine->context,
        {
        client          => $client,
        loginid         => $client->loginid,
        landing_company => $client->landing_company->short,
        residence       => $client->residence
        },
        'Context loginid and landing_company matches that of client';

    $rule_engine = BOM::Rules::Engine->new(loginid => $client->loginid);
    is_deeply $rule_engine->context,
        {
        client          => $client,
        loginid         => $client->loginid,
        landing_company => $client->landing_company->short,
        residence       => $client->residence
        },
        'Context client and landing_company matches that of loginid';

    $rule_engine = BOM::Rules::Engine->new(
        client          => $client,
        loginid         => 'test_loginid',
        landing_company => 'test_lc',
        residence       => 'xyz',
    );
    is_deeply $rule_engine->context,
        {
        client          => $client,
        loginid         => 'test_loginid',
        landing_company => 'test_lc',
        residence       => 'xyz',
        },
        'Context loginid, landing_company and residence are overriden by constructor args';
};

subtest 'Verify an action' => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    like exception { $rule_engine->verify_action() }, qr/Action name is required/;
    like exception { $rule_engine->verify_action('invalid_name_for_testing') }, qr/Unknown action 'invalid_name_for_testing' cannot be verified/;

    my @action_verify_args;
    my $mock_action = Test::MockModule->new('BOM::Rules::Registry::Action');
    $mock_action->redefine(verify => sub { @action_verify_args = @_; return 'Mock verification is called' });

    my $test_action = BOM::Rules::Registry::Action->new(
        name     => 'test_action',
        rule_set => []);
    my $mock_registry = Test::MockModule->new('BOM::Rules::Registry');
    $mock_registry->redefine('get_action' => sub { return $test_action });

    is $rule_engine->verify_action('test_action'), 'Mock verification is called';
    is scalar @action_verify_args, 3, 'Number of args is correct';
    my ($action, $context, $args) = @action_verify_args;
    is $action, $test_action, 'Correct action is sought';
    is $context, $rule_engine->context, 'Action verification is trggered with correct context';
    is_deeply $args, {}, 'Action is verified with empty args';

    undef @action_verify_args;
    is $rule_engine->verify_action(
        'test_action',
        {
            a => 1,
            b => 2,
        }
        ),
        'Mock verification is called';
    is scalar @action_verify_args, 3, 'Number of args is correct';
    ($action, $context, $args) = @action_verify_args;
    is $action, $test_action, 'Correct action is sought';
    is $context, $rule_engine->context, 'Action verification is trggered with correct context';
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
    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    like exception { $rule_engine->apply_rules() }, qr/Rule name cannot be empty/, 'Correct exception for empy rule name';
    like exception { $rule_engine->apply_rules('invalid_name_for_testing') }, qr/Unknown rule 'invalid_name_for_testing' cannot be applied/,
        'Correct error for invalid rule name';
    is_deeply $rule_engine->apply_rules([]), {return 1}, 'Empty rule array is accepted';

    my $test_rule = rule(
        name => 'test rule 1',
        code => sub { return 'result 1' });

    is_deeply $rule_engine->apply_rules('test rule 1'),   {return 1}, 'Rule is applied with default return value';
    is_deeply $rule_engine->apply_rules(['test rule 1']), {return 1}, 'Rule array is applied with default return value';

    my @rule_args;
    my $mock_rule = Test::MockModule->new('BOM::Rules::Registry::Rule');
    $mock_rule->redefine(apply => sub { @rule_args = @_; return 'Mock verification is called' });

    is $rule_engine->apply_rules(
        'test rule 1',
        {
            a => 1,
            b => 2,
        }
        ),
        'Mock verification is called',
        'Rule applied';
    is scalar @rule_args, 3, 'Number of args is correct';
    my ($rule, $context, $args) = @rule_args;
    is $rule, $test_rule, 'Correct rule is found';
    is $context, $rule_engine->context, 'Rule context is correct';
    is_deeply $args,
        {
        a => 1,
        b => 2
        },
        'Rule args are correct';

    $mock_rule->unmock_all;
};

done_testing();
