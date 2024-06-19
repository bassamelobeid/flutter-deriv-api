use strict;
use warnings;
no indirect;

use Test::Most;
use Test::Fatal;
use Test::Deep;
use Test::Warnings qw(warning);
use Test::MockModule;
use Test::MockObject;

use BOM::Rules::Registry qw(rule get_rule get_action);

subtest 'Rules registery' => sub {
    like exception { rule() },            qr/Rule name is required but missing/,        'Rule name is required';
    like exception { rule('test_rule') }, qr/No code associated with rule 'test_rule'/, 'Rule code is required';
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
    is $test_rule2->code,        \&test_sub,                      'Rule code is correctly set';
    isa_ok $test_rule2->apply(), 'BOM::Rules::Result', 'Rule code is correctly invoked';

    subtest 'Get rule' => sub {
        like exception { get_rule() }, qr/Rule name cannot be empty/, 'Rule name is required';
        is get_rule('test_rule'),    $test_rule, 'Correct rule is returned';
        is get_rule('invalid name'), undef,      'Empty result for non-existing rules';
    }
};

subtest 'Actions registery' => sub {
    my $rule1 = get_rule('test_rule');
    my $rule2 = get_rule('test_rule2');

    my $mock_action_data = {};
    my $mock_rule_groups = {};
    # the config path /actions has more than one file, which will make the test fails unless we mock to a single file
    my $mock_registry = Test::MockModule->new('BOM::Rules::Registry');
    $mock_registry->redefine('_get_config_files', sub { return ('test.yml') });

    my $mock_yml = Test::MockModule->new('YAML::XS');
    $mock_yml->redefine(
        'LoadFile',
        sub {
            my $path = shift;
            return $mock_action_data
                if $path =~ qr/actions/;
            return $mock_rule_groups
                if $path =~ qr/rule_groups/;
            return undef;
        });

    my $actions = BOM::Rules::Registry::register_actions();
    is_deeply $actions, {}, 'No action is registered';

    $mock_action_data = {'' => 0};
    like exception { BOM::Rules::Registry::register_actions() }, qr/Action name is required but missing/, 'Empty action name';

    $mock_action_data = {'action1' => 0};
    like exception { BOM::Rules::Registry::register_actions() }, qr/Configuration of action 'action1' doesn't look like a hash/,
        'Scalar rule set will fail';

    $mock_action_data = {'action1' => {dummy_key => []}};
    like exception { BOM::Rules::Registry::register_actions() }, qr/Action 'action1' doesn't have any 'ruleset'/, 'Scalar rule set will fail';

    $mock_action_data = {'action1' => {ruleset => [qw(test_rule invalid_rule)]}};
    like exception { BOM::Rules::Registry::register_actions() },
        qr/Rule 'invalid_rule' used in 'action1' was not found/, 'Invalid rule names cannot be used';

    $mock_action_data = {'action1' => {ruleset => []}};
    $actions          = BOM::Rules::Registry::register_actions();
    is_deeply [keys %$actions], ['action1'], 'Only one action is registered';
    is ref $actions->{action1}, 'BOM::Rules::Registry::Action', 'Action type is correct';
    is_deeply $actions,
        {
        action1 => {
            name        => 'action1',
            description => 'action1',
            category    => 'test',
            ruleset     => []}
        },
        'Action content is correct: empty rules and description defaulted to action name';

    like(
        warning { BOM::Rules::Registry::register_actions() },
        qr/Rule registery is already loaded /,
        'Correct warning when registering actions again'
    );

    # auto-reload actions on each 'register_actions' call
    $mock_registry->redefine(
        register_actions => sub { undef %BOM::Rules::Registry::action_registry; return $mock_registry->original(qw/register_actions/)->(@_) });

    $mock_action_data = {
        'action1' => {ruleset => ['test_rule']},
        'action2' => {ruleset => ['test_rule2']},
    };
    $actions = BOM::Rules::Registry::register_actions();
    cmp_bag [keys %$actions], [qw/action1 action2/], 'two actions are registered';
    is ref $actions->{$_}, 'BOM::Rules::Registry::Action', "Action $_ type is correct" for (qw/action1 action2/);

    is_deeply $actions->{action1}->{ruleset}, [$rule1], 'Rule set is correct';
    is_deeply $actions->{action2}->{ruleset}, [$rule2], 'Rule set is correct';

    $mock_action_data = {'action1' => {ruleset => {type => "abcd"}}};
    like exception { BOM::Rules::Registry::register_actions() },
        qr/Unknown composite rule type 'abcd' found in 'action1'; only 'conditional' and 'group' allowed/, 'Invalid conplex rule type';

    subtest 'conditional rules' => sub {
        $mock_action_data = {'action1' => {ruleset => [{type => "conditional"}]}};
        like exception { BOM::Rules::Registry::register_actions() },
            qr/Conditional rule without target arg found in action1 \('on' hash key not found\)/,
            'Conditional rule without a target property.';

        $mock_action_data->{action1}->{ruleset}->[0]->{on} = 'residence';
        like exception { BOM::Rules::Registry::register_actions() }, qr/Conditional rule rules_per_value found in action1/,
            'Conditional rule without rules_per_value';

        $mock_action_data->{action1}->{ruleset}->[0]->{rules_per_value} = {};
        is exception {
            $actions = BOM::Rules::Registry::register_actions()
        }, undef, 'The action registered successfully';
        cmp_bag [keys %$actions], [qw/action1/], 'a single action is registered';
        is ref $actions->{action1}, 'BOM::Rules::Registry::Action', "Action type is correct";
        is_deeply $actions->{action1}->{ruleset},
            [{
                'key'             => 'residence',
                'rules_per_value' => {
                    default => [],
                },
            },
            ],
            'rule set is correct';

        $mock_action_data->{action1}->{ruleset} = [
            'test_rule',
            'test_rule2',
            {
                type            => 'conditional',
                on              => 'residence',
                rules_per_value => {
                    id      => ['test_rule'],
                    de      => ['test_rule2'],
                    default => 'test_rule'
                },
            },
            {
                type            => 'conditional',
                on              => 'landing_company',
                rules_per_value => {mf => 'test_rule'},
            },
            {
                type            => 'conditional',
                on              => 'name',
                rules_per_value => {
                    Ali     => 'test_rule2',
                    default => 'test_rule'
                },
            },
        ];
        is exception {
            $actions = BOM::Rules::Registry::register_actions()
        }, undef, 'The action registered successfully';
        cmp_bag [keys %$actions], [qw/action1/], 'a single action is registered';
        is ref $actions->{action1}, 'BOM::Rules::Registry::Action', "Action type is correct";
        is_deeply $actions->{action1}->{ruleset},
            [
            get_rule('test_rule'),
            get_rule('test_rule2'),
            {
                'key'             => 'residence',
                'rules_per_value' => {
                    'id'      => [$rule1],
                    'de'      => [$rule2],
                    'default' => [$rule1],
                },
            },
            {
                'key'             => 'landing_company',
                'rules_per_value' => {
                    'mf'    => [$rule1],
                    default => [],
                },
            },
            {
                'key'             => 'name',
                'rules_per_value' => {
                    'Ali'     => [$rule2],
                    'default' => [$rule1],
                },
            },
            ];

    };

    subtest 'Rule groups' => sub {
        $mock_action_data = {
            'action1' => {
                ruleset => [{
                        type => 'group',
                    }]
            },
        };

        my $actions = BOM::Rules::Registry::register_actions();
        is_deeply $actions,
            {
            action1 => {
                name        => 'action1',
                description => 'action1',
                category    => 'test',
                ruleset     => [{
                        ruleset            => [],
                        name               => 'anonymous',
                        description        => 'Unnamed group in action configuration',
                        required_arguments => [],
                        argument_mapping   => {},
                        tag                => undef,
                    }
                ],
            }};

        $mock_action_data = {
            'action1' => {
                ruleset => [
                    'test_rule',
                    {
                        type             => 'group',
                        name             => 'test rule group',
                        description      => 'created for testing inline rule groups',
                        argument_mapping => {
                            arg1 => 'first_name',
                            arg2 => 'last_name',
                        },
                        ruleset => ['test_rule2'],
                        tag     => undef,
                    }]
            },
        };

        $actions = BOM::Rules::Registry::register_actions();
        is_deeply $actions,
            {
            action1 => {
                name        => 'action1',
                description => 'action1',
                category    => 'test',
                ruleset     => [
                    $rule1,
                    {
                        name               => 'test rule group',
                        description        => 'created for testing inline rule groups',
                        required_arguments => [],
                        argument_mapping   => {
                            arg1 => 'first_name',
                            arg2 => 'last_name',
                        },
                        ruleset => [$rule2],
                        tag     => undef
                    }
                ],
            }
            },
            'A ruleset consisting of a simple rule and a rule-group';

        # TODO: we cannot ceate a real context object in this test script,
        # because of the circular dependency with bom-user; a mock object is use instead.
        my $context = BOM::Rules::Context->new(stop_on_failure => 0);

        is_deeply $actions->{action1}->verify($context),
            {
            failed_rules => [],
            errors       => {},
            has_failure  => 0,
            passed_rules => ['test_rule', 'test_rule2']
            },
            'Both rules are applied';

        subtest 'Argument mapping' => sub {
            my $failing_rule = rule(
                'failing_rule' => {
                    code        => sub { my ($self, $context, $args) = @_; die $args },
                    description => "This rule dies with it's args"
                });

            $mock_action_data = {
                'action1' => {
                    ruleset => [{
                            type             => 'group',
                            name             => 'test rule group',
                            description      => 'created for testing inline rule groups',
                            argument_mapping => {
                                arg1 => 'first_name',
                                arg2 => 'last_name',
                            },
                            ruleset => ['failing_rule'],
                        },
                        'test_rule',
                    ]
                },
            };

            my $action_args = {
                first_name => 'Ali',
                last_name  => 'Smith',
                a          => 11
            };
            $actions = BOM::Rules::Registry::register_actions();
            is_deeply $actions->{action1}->verify($context, $action_args),
                {
                failed_rules => [{
                        rule       => 'failing_rule',
                        arg1       => 'Ali',
                        arg2       => 'Smith',
                        first_name => 'Ali',
                        last_name  => 'Smith',
                        a          => 11,
                    },
                ],
                errors       => {},
                has_failure  => 1,
                passed_rules => ['test_rule']
                },
                'Arguments are mapped correctly';
        };

        subtest 'Named rule group' => sub {
            $mock_rule_groups = [{
                    group1 => [],
                }];
            like exception { BOM::Rules::Registry::register_actions() }, qr/Invalid config file structure in test.yml/,
                'Correct error for invalid rule-group file content';

            $mock_rule_groups = {
                group1 => [],
            };
            like exception { BOM::Rules::Registry::register_actions() }, qr/Config of rule-group 'group1' doesn't look like a hash/,
                'Correct error for invalid rule-group structure';

            $mock_rule_groups = {
                group1 => {},
            };
            like exception { BOM::Rules::Registry::register_actions() }, qr/Rule-group 'group1' doesn't have any 'ruleset'/,
                'Ruleset is required for a rule-group';

            $mock_rule_groups = {group1 => {ruleset => [qw/invalid_rule/]}};
            like exception { BOM::Rules::Registry::register_actions() }, qr/Rule 'invalid_rule' used in 'ruleset test.yml -> group1' was not found/,
                'Rule names are validated';

            $mock_rule_groups = {group1 => {ruleset => [qw/failing_rule test_rule/]}};
            lives_ok { BOM::Rules::Registry::register_actions() } 'Rule group created with minimum required info';

            $mock_rule_groups = {
                group1 => {
                    description        => 'Test rule-group with required args',
                    required_arguments => [qw/arg1 arg2/],
                    ruleset            => [qw/failing_rule test_rule/]}};
            $mock_action_data = {
                action1 => {
                    ruleset => [{
                            type       => 'group',
                            rule_group => 'invalid_group_name'
                        },
                        'test_rule2',
                    ]
                },
            };
            like exception { BOM::Rules::Registry::register_actions() }, qr/Invalid group name invalid_group_name found in action1/,
                'Correct exception for a non-exsting rule-group invocation';

            my $rule_group_incovation = $mock_action_data->{action1}->{ruleset}->[0];
            $rule_group_incovation->{rule_group} = 'group1';
            $rule_group_incovation->{ruleset}    = [qw/test_rule test_rule2/];
            like exception { BOM::Rules::Registry::register_actions() },
                qr/Ruleset incorrectly declared for a known rule-group \(group1\) in action1/,
                'Correct exception if ruleset is declared for a named rule-group invocation';

            delete $rule_group_incovation->{ruleset};
            lives_ok { $actions = BOM::Rules::Registry::register_actions() } 'The rule-group is loaded by an action';
            like exception { $actions->{action1}->verify($context) }, qr/No value found for required argument 'arg1'/,
                'Required arguments should be mapped or found in action args.';

            $rule_group_incovation->{argument_mapping} = {
                arg1 => "'literal value'",
            };
            $actions = BOM::Rules::Registry::register_actions();
            like exception { $actions->{action1}->verify($context) }, qr/No value found for required argument 'arg2'/,
                'Arg1 is set with a literal value; arg2 is remaining.';

            my $action_args = {
                arg2 => 'taken from action args without mapping',
                arg3 => 'additional action argument',
            };
            my $result;
            lives_ok {
                $actions = BOM::Rules::Registry::register_actions();
                $result  = $actions->{action1}->verify($context, $action_args);
            }
            'Arg2 was correctly taken from action args';

            is_deeply $result,
                {
                failed_rules => [{
                        rule => 'failing_rule',
                        arg1 => 'literal value',
                        arg2 => 'taken from action args without mapping',
                        arg3 => 'additional action argument',
                    }
                ],
                errors       => {},
                has_failure  => 1,
                passed_rules => [qw/test_rule test_rule2/],
                },
                'Rules are applied as expected';
        };
    };

    subtest 'Rule groups' => sub {
        $mock_action_data = {
            'action1' => {
                ruleset => [{
                        type => 'group',
                    }]
            },
        };

        my $actions = BOM::Rules::Registry::register_actions();
        is_deeply $actions,
            {
            action1 => {
                name        => 'action1',
                description => 'action1',
                category    => 'test',
                ruleset     => [{
                        ruleset            => [],
                        name               => 'anonymous',
                        description        => 'Unnamed group in action configuration',
                        required_arguments => [],
                        argument_mapping   => {},
                        tag                => undef,
                    }
                ],
            }};

        $mock_action_data = {
            'action1' => {
                ruleset => [
                    'test_rule',
                    {
                        type             => 'group',
                        name             => 'test rule group',
                        description      => 'created for testing inline rule groups',
                        argument_mapping => {
                            arg1 => 'first_name',
                            arg2 => 'last_name',
                        },
                        ruleset => ['test_rule2']}]
            },
        };

        $actions = BOM::Rules::Registry::register_actions();
        is_deeply $actions,
            {
            action1 => {
                name        => 'action1',
                description => 'action1',
                category    => 'test',
                ruleset     => [
                    $rule1,
                    {
                        name               => 'test rule group',
                        description        => 'created for testing inline rule groups',
                        required_arguments => [],
                        argument_mapping   => {
                            arg1 => 'first_name',
                            arg2 => 'last_name',
                        },
                        ruleset => [$rule2],
                        tag     => undef,
                    }
                ],
            }
            },
            'A ruleset consisting of a simple rule and a rule-group';

        # TODO: we cannot ceate a real context object in this test script,
        # because of the circular dependency with bom-user; a mock object is use instead.
        my $context = Test::MockObject->new();
        $context->mock(stop_on_failure => sub { return 0 });

        is_deeply $actions->{action1}->verify($context),
            {
            failed_rules => [],
            errors       => {},
            has_failure  => 0,
            passed_rules => ['test_rule', 'test_rule2']
            },
            'Both rules are applied';

        subtest 'Argument mapping' => sub {
            my $failing_rule = rule(
                'failing_rule2' => {
                    code        => sub { my ($self, $context, $args) = @_; die $args },
                    description => "This rule dies with it's args"
                });

            $mock_action_data = {
                'action1' => {
                    ruleset => [{
                            type             => 'group',
                            name             => 'test rule group',
                            description      => 'created for testing inline rule groups',
                            argument_mapping => {
                                arg1 => 'first_name',
                                arg2 => 'last_name',
                            },
                            ruleset => ['failing_rule2'],
                        },
                        'test_rule',
                    ]
                },
            };

            my $action_args = {
                first_name => 'Ali',
                last_name  => 'Smith',
                a          => 11
            };
            $actions = BOM::Rules::Registry::register_actions();
            is_deeply $actions->{action1}->verify($context, $action_args),
                {
                failed_rules => [{
                        rule       => 'failing_rule2',
                        arg1       => 'Ali',
                        arg2       => 'Smith',
                        first_name => 'Ali',
                        last_name  => 'Smith',
                        a          => 11,
                    },
                ],
                errors       => {},
                has_failure  => 1,
                passed_rules => ['test_rule']
                },
                'Arguments are mapped correctly';
        };

        subtest 'Named rule group' => sub {
            $mock_rule_groups = [{
                    group1 => [],
                }];
            like exception { BOM::Rules::Registry::register_actions() }, qr/Invalid config file structure in test.yml/,
                'Correct error for invalid rule-group file content';

            $mock_rule_groups = {
                group1 => [],
            };
            like exception { BOM::Rules::Registry::register_actions() }, qr/Config of rule-group 'group1' doesn't look like a hash/,
                'Correct error for invalid rule-group structure';

            $mock_rule_groups = {
                group1 => {},
            };
            like exception { BOM::Rules::Registry::register_actions() }, qr/Rule-group 'group1' doesn't have any 'ruleset'/,
                'Ruleset is required for a rule-group';

            $mock_rule_groups = {group1 => {ruleset => [qw/invalid_rule/]}};
            like exception { BOM::Rules::Registry::register_actions() }, qr/Rule 'invalid_rule' used in 'ruleset test.yml -> group1' was not found/,
                'Rule names are validated';

            $mock_rule_groups = {group1 => {ruleset => [qw/failing_rule test_rule/]}};
            lives_ok { BOM::Rules::Registry::register_actions() } 'Rule group created with minimum required info';

            $mock_rule_groups = {
                group1 => {
                    description        => 'Test rule-group with required args',
                    required_arguments => [qw/arg1 arg2/],
                    ruleset            => [qw/failing_rule test_rule/]}};
            $mock_action_data = {
                action1 => {
                    ruleset => [{
                            type       => 'group',
                            rule_group => 'invalid_group_name'
                        },
                        'test_rule2',
                    ]
                },
            };
            like exception { BOM::Rules::Registry::register_actions() }, qr/Invalid group name invalid_group_name found in action1/,
                'Correct exception for a non-exsting rule-group invocation';

            my $rule_group_incovation = $mock_action_data->{action1}->{ruleset}->[0];
            $rule_group_incovation->{rule_group} = 'group1';
            $rule_group_incovation->{ruleset}    = [qw/test_rule test_rule2/];
            like exception { BOM::Rules::Registry::register_actions() },
                qr/Ruleset incorrectly declared for a known rule-group \(group1\) in action1/,
                'Correct exception if ruleset is declared for a named rule-group invocation';

            delete $rule_group_incovation->{ruleset};
            lives_ok { $actions = BOM::Rules::Registry::register_actions() } 'The rule-group is loaded by an action';
            like exception { $actions->{action1}->verify($context) }, qr/No value found for required argument 'arg1'/,
                'Required arguments should be mapped or found in action args.';

            $rule_group_incovation->{argument_mapping} = {
                arg1 => "'literal value'",
            };
            $actions = BOM::Rules::Registry::register_actions();
            like exception { $actions->{action1}->verify($context) }, qr/No value found for required argument 'arg2'/,
                'Arg1 is set with a literal value; arg2 is remaining.';

            my $action_args = {
                arg2 => 'taken from action args without mapping',
                arg3 => 'additional action argument',
            };
            my $result;
            lives_ok {
                $actions = BOM::Rules::Registry::register_actions();
                $result  = $actions->{action1}->verify($context, $action_args);
            }
            'Arg2 was correctly taken from action args';

            is_deeply $result,
                {
                failed_rules => [{
                        rule => 'failing_rule',
                        arg1 => 'literal value',
                        arg2 => 'taken from action args without mapping',
                        arg3 => 'additional action argument',
                    }
                ],
                errors       => {},
                has_failure  => 1,
                passed_rules => [qw/test_rule test_rule2/],
                },
                'Rules are applied as expected';
        };
    };

    subtest 'Rule groups' => sub {
        $mock_action_data = {
            'action1' => {
                ruleset => [{
                        type => 'group',
                        tag  => undef
                    }]
            },
        };

        my $actions = BOM::Rules::Registry::register_actions();
        is_deeply $actions,
            {
            action1 => {
                name        => 'action1',
                description => 'action1',
                category    => 'test',
                ruleset     => [{
                        ruleset            => [],
                        name               => 'anonymous',
                        description        => 'Unnamed group in action configuration',
                        required_arguments => [],
                        argument_mapping   => {},
                        tag                => undef,
                    }
                ],
            }};

        $mock_action_data = {
            'action1' => {
                ruleset => [
                    'test_rule',
                    {
                        type             => 'group',
                        name             => 'test rule group',
                        description      => 'created for testing inline rule groups',
                        argument_mapping => {
                            arg1 => 'first_name',
                            arg2 => 'last_name',
                        },
                        ruleset => ['test_rule2'],
                    }]
            },
        };

        $actions = BOM::Rules::Registry::register_actions();
        is_deeply $actions,
            {
            action1 => {
                name        => 'action1',
                description => 'action1',
                category    => 'test',
                ruleset     => [
                    $rule1,
                    {
                        name               => 'test rule group',
                        description        => 'created for testing inline rule groups',
                        required_arguments => [],
                        argument_mapping   => {
                            arg1 => 'first_name',
                            arg2 => 'last_name',
                        },
                        ruleset => [$rule2],
                        tag     => undef
                    }
                ],
            }
            },
            'A ruleset consisting of a simple rule and a rule-group';

        # TODO: we cannot ceate a real context object in this test script,
        # because of the circular dependency with bom-user; a mock object is use instead.
        my $context = Test::MockObject->new();
        $context->mock(stop_on_failure => sub { return 0 });

        is_deeply $actions->{action1}->verify($context),
            {
            failed_rules => [],
            errors       => {},
            has_failure  => 0,
            passed_rules => ['test_rule', 'test_rule2']
            },
            'Both rules are applied';

        subtest 'Argument mapping' => sub {
            my $failing_rule = rule(
                'failing_rule3' => {
                    code        => sub { my ($self, $context, $args) = @_; die $args },
                    description => "This rule dies with it's args"
                });

            $mock_action_data = {
                'action1' => {
                    ruleset => [{
                            type             => 'group',
                            name             => 'test rule group',
                            description      => 'created for testing inline rule groups',
                            argument_mapping => {
                                arg1 => 'first_name',
                                arg2 => 'last_name',
                            },
                            ruleset => ['failing_rule3'],
                        },
                        'test_rule',
                    ]
                },
            };

            my $action_args = {
                first_name => 'Ali',
                last_name  => 'Smith',
                a          => 11
            };
            $actions = BOM::Rules::Registry::register_actions();
            is_deeply $actions->{action1}->verify($context, $action_args),
                {
                failed_rules => [{
                        rule       => 'failing_rule3',
                        arg1       => 'Ali',
                        arg2       => 'Smith',
                        first_name => 'Ali',
                        last_name  => 'Smith',
                        a          => 11,
                    },
                ],
                errors       => {},
                has_failure  => 1,
                passed_rules => ['test_rule']
                },
                'Arguments are mapped correctly';
        };

        subtest 'Named rule group' => sub {
            $mock_rule_groups = [{
                    group1 => [],
                }];
            like exception { BOM::Rules::Registry::register_actions() }, qr/Invalid config file structure in test.yml/,
                'Correct error for invalid rule-group file content';

            $mock_rule_groups = {
                group1 => [],
            };
            like exception { BOM::Rules::Registry::register_actions() }, qr/Config of rule-group 'group1' doesn't look like a hash/,
                'Correct error for invalid rule-group structure';

            $mock_rule_groups = {
                group1 => {},
            };
            like exception { BOM::Rules::Registry::register_actions() }, qr/Rule-group 'group1' doesn't have any 'ruleset'/,
                'Ruleset is required for a rule-group';

            $mock_rule_groups = {group1 => {ruleset => [qw/invalid_rule/]}};
            like exception { BOM::Rules::Registry::register_actions() }, qr/Rule 'invalid_rule' used in 'ruleset test.yml -> group1' was not found/,
                'Rule names are validated';

            $mock_rule_groups = {group1 => {ruleset => [qw/failing_rule test_rule/]}};
            lives_ok { BOM::Rules::Registry::register_actions() } 'Rule group created with minimum required info';

            $mock_rule_groups = {
                group1 => {
                    description        => 'Test rule-group with required args',
                    required_arguments => [qw/arg1 arg2/],
                    ruleset            => [qw/failing_rule test_rule/],
                }};
            $mock_action_data = {
                action1 => {
                    ruleset => [{
                            type       => 'group',
                            rule_group => 'invalid_group_name',
                        },
                        'test_rule2',
                    ]
                },
            };
            like exception { BOM::Rules::Registry::register_actions() }, qr/Invalid group name invalid_group_name found in action1/,
                'Correct exception for a non-exsting rule-group invocation';

            my $rule_group_incovation = $mock_action_data->{action1}->{ruleset}->[0];
            $rule_group_incovation->{rule_group} = 'group1';
            $rule_group_incovation->{ruleset}    = [qw/test_rule test_rule2/];
            like exception { BOM::Rules::Registry::register_actions() },
                qr/Ruleset incorrectly declared for a known rule-group \(group1\) in action1/,
                'Correct exception if ruleset is declared for a named rule-group invocation';

            delete $rule_group_incovation->{ruleset};
            lives_ok { $actions = BOM::Rules::Registry::register_actions() } 'The rule-group is loaded by an action';
            like exception { $actions->{action1}->verify($context) }, qr/No value found for required argument 'arg1'/,
                'Required arguments should be mapped or found in action args.';

            $rule_group_incovation->{argument_mapping} = {
                arg1 => "'literal value'",
            };
            $actions = BOM::Rules::Registry::register_actions();
            like exception { $actions->{action1}->verify($context) }, qr/No value found for required argument 'arg2'/,
                'Arg1 is set with a literal value; arg2 is remaining.';

            my $action_args = {
                arg2 => 'taken from action args without mapping',
                arg3 => 'additional action argument',
            };
            my $result;
            lives_ok {
                $actions = BOM::Rules::Registry::register_actions();
                $result  = $actions->{action1}->verify($context, $action_args);
            }
            'Arg2 was correctly taken from action args';

            is_deeply $result,
                {
                failed_rules => [{
                        rule => 'failing_rule',
                        arg1 => 'literal value',
                        arg2 => 'taken from action args without mapping',
                        arg3 => 'additional action argument',
                    }
                ],
                errors       => {},
                has_failure  => 1,
                passed_rules => [qw/test_rule test_rule2/],
                },
                'Rules are applied as expected';
        };

        subtest 'Rule group tags' => sub {
            $mock_rule_groups = {
                group1 => {
                    description        => 'Test rule-group with required args',
                    required_arguments => [qw/arg1 arg2/],
                    ruleset            => [qw/failing_rule test_rule/],
                }};
            $mock_action_data = {
                action1 => {
                    ruleset => [{
                            type       => 'group',
                            rule_group => 'group1',
                            tag        => 'named group',
                        },
                        {
                            type    => 'group',
                            ruleset => [qw/failing_rule test_rule/],
                            tag     => 'anonymous group'
                        },
                    ]
                },
            };

            my $action_args = {
                arg1 => 'value1',
                arg2 => 'value2',
            };
            my $context = BOM::Rules::Context->new(stop_on_failure => 0);
            $actions = BOM::Rules::Registry::register_actions();
            my $result;
            lives_ok {
                $result = $actions->{action1}->verify($context, $action_args);
            }
            'Action is verified successfully';

            is_deeply $result,
                {
                failed_rules => [{
                        rule => 'failing_rule',
                        arg1 => 'value1',
                        arg2 => 'value2',
                        tags => ['named group'],
                    },
                    {
                        rule => 'failing_rule',
                        arg1 => 'value1',
                        arg2 => 'value2',
                        tags => ['anonymous group'],
                    }
                ],
                errors       => {},
                has_failure  => 1,
                passed_rules => [qw/test_rule test_rule/],
                },
                'Tags correctly appear in the failing rules';

            # with stop on failure
            $context = BOM::Rules::Context->new(stop_on_failure => 1);
            is_deeply exception { $actions->{action1}->verify($context, $action_args) },
                {
                arg1 => 'value1',
                arg2 => 'value2',
                tags => ['named group'],
                },
                'tags correctly appear in the exception';

        };
    };

    $mock_yml->unmock_all;
    $mock_registry->unmock_all;
};

done_testing();
