use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::Warnings qw(warning);
use Test::MockModule;

use BOM::Rules::Registry qw(rule get_rule get_action);

subtest 'Rules registery' => sub {
    like exception { rule() }, qr/Rule name is required but missing/, 'Rule name is required';
    like exception { rule('test_rule') }, qr/No code associated with rule 'test_rule'/, 'Rule code is required';
    like exception { rule('test_rule' => {error_code => 'scalar value'}) }, qr/No code associated with rule 'test_rule'/,
        'Rule code should be of correct type';
    like exception { rule('test_rule' => {error_code => {}}) }, qr/No code associated with rule 'test_rule'/, 'Rule code should be of correct type';
    my $test_rule = rule(
        'test_rule' => {
            code => sub { return 'test result' }
        });
    ok $test_rule, 'Rule is registered successfully';
    is $test_rule->name,        'test_rule', 'Rule name is correct';
    is $test_rule->description, 'test_rule', "Rule description is defaulted to it's name";
    isa_ok $test_rule->apply(), 'BOM::Rules::Result', 'Rule code is correctly set';

    like exception {
        rule(
            'test_rule' => {
                code => sub { return 2 }
            })
    }, qr/Rule 'test_rule' is already registered/, 'Duplicate rule names are not acceptable';
    sub test_sub { return 'result 2' }
    my $test_rule2 = rule(
        'test_rule2' => {
            code        => \&test_sub,
            description => 'This rule is for testing only'
        });
    is $test_rule2->name,        'test_rule2',                    'Rule name is correct';
    is $test_rule2->description, 'This rule is for testing only', 'Rule description is correctly set';
    is $test_rule2->code,        \&test_sub, 'Rule code is correctly set';
    isa_ok $test_rule2->apply(), 'BOM::Rules::Result', 'Rule code is correctly invoked';

    subtest 'Get rule' => sub {
        like exception { get_rule() }, qr/Rule name cannot be empty/, 'Rule name is required';
        is get_rule('test_rule'), $test_rule, 'Correct rule is returned';
        is get_rule('invalid name'), undef, 'Empty result for non-existing rules';
    }
};

subtest 'Actions registery' => sub {
    my $rule1 = get_rule('test_rule');
    my $rule2 = get_rule('test_rule2');

    my $mock_data = {};

    my $mock_yml = Test::MockModule->new('YAML::XS');
    $mock_yml->redefine('LoadFile', sub { return $mock_data });

    # when /actions has more than one file the test fails unless we mock to a single file
    my $mock_registry = Test::MockModule->new('BOM::Rules::Registry');
    $mock_registry->redefine('_get_action_files', sub { return ('action.yml') });

    my $actions = BOM::Rules::Registry::register_actions();
    is_deeply $actions, {}, 'No action is registered';

    $mock_data = {'' => 0};
    like exception { BOM::Rules::Registry::register_actions() }, qr/Action name is required but missing/, 'Empty action name';

    $mock_data = {'action1' => 0};
    like exception { BOM::Rules::Registry::register_actions() }, qr/Rule set of action 'action1' is not a hash/, 'Scalar rule set will fail';

    $mock_data = {'action1' => 0};
    like exception { BOM::Rules::Registry::register_actions() }, qr/Rule set of action 'action1' is not a hash/, 'Scalar rule set will fail';

    $mock_data = {'action1' => {dummy_key => []}};
    like exception { BOM::Rules::Registry::register_actions() }, qr/Rule 'action1' doesn't have any 'ruleset/, 'Scalar rule set will fail';

    $mock_data = {'action1' => {ruleset => {dummy_key => []}}};
    like exception { BOM::Rules::Registry::register_actions() },
        qr/Invalid condition type 'dummy_key' in action 'action1': only 'context' and 'args' are acceptable/, 'Scalar rule set will fail';

    $mock_data = {'action1' => {ruleset => [qw(test_rule invalid_rule)]}};
    like exception { BOM::Rules::Registry::register_actions() },
        qr/Rule 'invalid_rule' used in action 'action1' was not found/, 'Invalid rule names cannot be used';

    $mock_data = {'action1' => {ruleset => []}};
    $actions   = BOM::Rules::Registry::register_actions();
    is_deeply [keys %$actions], ['action1'], 'Only one action is registered';
    is ref $actions->{action1}, 'BOM::Rules::Registry::Action', 'Action type is correct';
    is_deeply $actions->{action1}->{rule_set}, [], 'Rule set is empty';
    is $actions->{action1}->{description}, 'action1', 'Rule description is defaulted to its name';

    like(
        warning { BOM::Rules::Registry::register_actions() },
        qr/Rule registery is already loaded /,
        'Correct warning when registering actions again'
    );

    $mock_registry->redefine(
        register_actions => sub { undef %BOM::Rules::Registry::action_registry; return $mock_registry->original(qw/register_actions/)->(@_) });
    $mock_yml->redefine('LoadFile', sub { undef %BOM::Rules::Registry::action_registry; return $mock_data; });

    $mock_data = {
        'action1' => {ruleset => ['test_rule']},
        'action2' => {ruleset => ['test_rule2']},
    };
    $actions = BOM::Rules::Registry::register_actions();
    cmp_bag [keys %$actions], [qw/action1 action2/], 'two actions are registered';
    is ref $actions->{$_}, 'BOM::Rules::Registry::Action', "Action $_ type is correct" for (qw/action1 action2/);

    is_deeply $actions->{action1}->{rule_set}, [$rule1], 'Rule set is correct';
    is_deeply $actions->{action2}->{rule_set}, [$rule2], 'Rule set is correct';

    subtest 'conditional rules' => sub {
        $mock_data = {'action1' => {ruleset => {context => {invalid_key => 'test_rule'}}}};
        like exception { BOM::Rules::Registry::register_actions() },
            qr/Invalid context key 'invalid_key' used for a conditional rule in action 'action1'/, 'Invalid context key will fail';

        $mock_data->{action1}->{ruleset}->{context} = {residence => 'test_rule'};
        like exception { BOM::Rules::Registry::register_actions() },
            qr/Conditional structure of rule 'context->residence' in action 'action1' is not a hash/, 'Invalid conditional structure will fail';

        $mock_data->{action1}->{ruleset}->{context} = {
            residence => {
                id => ['test_rule'],
                de => ['rule_xyz']}};

        like exception { BOM::Rules::Registry::register_actions() },
            qr/Rule 'rule_xyz' used in action 'action1' was not found/, 'Invalid names cannot be used in coditional rules';

        $mock_data->{action1}->{ruleset} = [
            'test_rule',
            'test_rule2',
            {
                context => {
                    residence => {
                        id      => ['test_rule'],
                        de      => ['test_rule2'],
                        default => 'test_rule'
                    },
                },
            },
            {
                context => {
                    landing_company => {mf => 'test_rule'},
                },
            },
            {
                args => {
                    name => {
                        Ali     => 'test_rule2',
                        default => 'test_rule'
                    }
                },
            },
        ];
        $actions = BOM::Rules::Registry::register_actions();
        cmp_bag [keys %$actions], [qw/action1/], 'a single action is registered';
        is ref $actions->{action1}, 'BOM::Rules::Registry::Action', "Action type is correct";
        is_deeply $actions->{action1}->{rule_set},
            [
            get_rule('test_rule'),
            get_rule('test_rule2'),
            {
                'context_key'     => 'residence',
                'rules_per_value' => {
                    'id'      => [$rule1],
                    'de'      => [$rule2],
                    'default' => [$rule1],
                },
            },
            {
                'context_key'     => 'landing_company',
                'rules_per_value' => {
                    'mf' => [$rule1],
                },
            },
            {
                'args_key'        => 'name',
                'rules_per_value' => {
                    'Ali'     => [$rule2],
                    'default' => [$rule1],
                },
            }];

    };

    $mock_yml->unmock_all;
    $mock_registry->unmock_all;
};

done_testing();
