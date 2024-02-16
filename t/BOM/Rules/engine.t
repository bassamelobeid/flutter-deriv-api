use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User;
use BOM::Rules::Engine;
use BOM::Rules::Registry qw(register_action rule);
use BOM::Rules::Registry::Action;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my $user = BOM::User->create(
    email    => $client->email,
    password => 'x',
);

$user->add_client($client);

subtest 'Context initialization' => sub {
    my $rule_engine = BOM::Rules::Engine->new(stop_on_failure => 0);
    is $rule_engine->context->stop_on_failure, 0, 'stop_on_failure = 0 is saved in the context';

    $rule_engine = BOM::Rules::Engine->new();
    is $rule_engine->context->stop_on_failure, 1, 'Stop_on_failure is defaulted  to 1.';

    $rule_engine = BOM::Rules::Engine->new(stop_on_failure => 1);
    is $rule_engine->context->stop_on_failure, 1, 'stop_on_failure = 1 is saved in the context';

    $rule_engine = BOM::Rules::Engine->new(client => $client);
    is $rule_engine->context->client({loginid => $client->loginid})->loginid, $client->loginid, 'client saved in the context';

    $rule_engine = BOM::Rules::Engine->new(user => $user);
    is $rule_engine->context->user->id, $user->id, 'user saved in the context';

};

subtest 'Verify an action' => sub {
    my $rule_engine_1 = BOM::Rules::Engine->new();
    like exception { $rule_engine_1->verify_action() }, qr/Action name is required/, 'exception thrown on verify without providing action';
    like exception { $rule_engine_1->verify_action('invalid_name_for_testing') }, qr/Unknown action 'invalid_name_for_testing' cannot be verified/,
        'exception thrown on invalid name for testing';

    my @action_verify_args;
    my $mock_action = Test::MockModule->new('BOM::Rules::Registry::Action');
    $mock_action->redefine(verify => sub { @action_verify_args = @_; return $mock_action->original('verify')->(@_); });

    my $test_action = BOM::Rules::Registry::Action->new(
        name    => 'test_action',
        ruleset => []);
    my $mock_registry = Test::MockModule->new('BOM::Rules::Registry');
    $mock_registry->redefine('get_action' => sub { return $test_action });

    ok $rule_engine_1->verify_action('test_action'), 'action result is as expected';
    is scalar @action_verify_args, 3, 'Number of args is correct';
    my ($action, $context, $args) = @action_verify_args;
    is $action, $test_action, 'Correct action is cought';
    is_deeply $context, {$rule_engine_1->context->%*, action => 'test_action'}, 'Correct context, action name included.';
    is_deeply $args,    {},                                                     'Action is verified with empty args';

    undef @action_verify_args;
    isa_ok $rule_engine_1->verify_action(
        'test_action',
        a => 1,
        b => 2,
        ),
        'BOM::Rules::Result', 'action result is as expected';
    is scalar @action_verify_args, 3, 'Number of args is correct';
    ($action, $context, $args) = @action_verify_args;
    is $action, $test_action, 'Correct action is sought';
    is_deeply $context, {$rule_engine_1->context->%*, action => 'test_action'}, 'Correct context, action name included.';
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
        failed_rules => [],
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
        failed_rules => [],
        errors       => {},
        passed_rules => ['test rule 1']
        },
        'Rule is applied with default return value';
    is_deeply $rule_engine_1->apply_rules(['test rule 1']),
        {
        has_failure  => 0,
        failed_rules => [],
        errors       => {},
        passed_rules => ['test rule 1']
        },
        'Rule array is applied with default return value';

    my @rule_args;
    my $mock_rule = Test::MockModule->new('BOM::Rules::Registry::Rule');
    $mock_rule->redefine(apply => sub { @rule_args = @_; return $mock_rule->original('apply')->(@_); });

    is $rule_engine_1->apply_rules(
        'test rule 1',
        a => 1,
        b => 2,
    )->{has_failure}, 0, 'Rule applied';
    is scalar @rule_args, 3, 'Number of args is correct';
    my ($rule, $context, $args) = @rule_args;
    is $rule, $test_rule, 'Correct rule is found';
    is_deeply $context, $rule_engine_1->context, 'Rule context is correct';
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

    my $full_report = {
        has_failure  => 1,
        failed_rules => [{
                rule => 'failing rule',
                code => 'DummyError'
            }
        ],
        errors       => {DummyError => 1},
        passed_rules => []};
    is_deeply $rule_engine_1->apply_rules('failing rule', rule_engine_context => {stop_on_failure => 0}),
        $full_report, 'override_context can override stop-on-failure';

    my $rule_engine_2 = BOM::Rules::Engine->new(
        client          => $client,
        stop_on_failure => 0
    );

    is_deeply $rule_engine_2->apply_rules('failing rule'), $full_report, 'Correct report for a failing rule';

    is_deeply $rule_engine_2->apply_rules(['failing rule', 'test rule 1', 'failing rule2']),
        {
        has_failure  => 1,
        failed_rules => [{
                rule => 'failing rule',
                code => 'DummyError'
            },
            {
                rule => 'failing rule2',
                code => 'DummyError2'
            }
        ],
        errors => {
            DummyError  => 1,
            DummyError2 => 1
        },
        passed_rules => ['test rule 1']
        },
        'Correct result for three rules (two failing and one passing)';
};

subtest 'Sample rule-gruop and action' => sub {
    # the config path /actions has more than one file, which will make the test fails unless we mock to a single file
    my $mock_registry = Test::MockModule->new('BOM::Rules::Registry');
    $mock_registry->redefine('_get_config_files', sub { return ('test.yml') });

    my $mock_yml = Test::MockModule->new('YAML::XS');
    $mock_yml->redefine(
        'LoadFile',
        sub {
            my $path = shift;
            if ($path =~ qr/actions/) {
                $path = '/home/git/regentmarkets/bom-rules/t/data/sample_action.yml';
            } elsif ($path =~ qr/rule_groups/) {
                $path = '/home/git/regentmarkets/bom-rules/t/data/sample_group.yml';
            }

            return $mock_yml->original('LoadFile')->($path, @_);
        });

    undef %BOM::Rules::Registry::action_registry;
    my $actions = BOM::Rules::Registry::register_actions();
    is scalar(keys %$actions), 1, 'Only one action is loaded';

    my $rule_engine = BOM::Rules::Engine->new(stop_on_failure => 0);
    like exception { $rule_engine->verify_action('demo_action_with_groups') }, qr/Client loginid is missing/, 'Required args are missing';
    my $args = {
        account_currency => 'USD',
        company_name     => 'svg',
        loginid          => $client->loginid
    };
    like exception { $rule_engine->verify_action('demo_action_with_groups', %$args) }, qr/Client with id .* was not found/,
        'Client object is missing';

    $rule_engine = BOM::Rules::Engine->new(
        stop_on_failure => 0,
        client          => $client
    );
    my $result = $rule_engine->verify_action('demo_action_with_groups', %$args);
    is $result->has_failure, 1, 'One rule has failed';
    is_deeply $result->failed_rules,
        [{
            rule       => 'profile.valid_profile_countries',
            error_code => 'InvalidPlaceOfBirth',
        }];
    is_deeply $result->passed_rules,
        ['client.is_not_virtual', 'residence.not_restricted', 'landing_company.currency_is_allowed', 'currency.is_available_for_change'],
        "Correct list of applied rules";
};

done_testing();
