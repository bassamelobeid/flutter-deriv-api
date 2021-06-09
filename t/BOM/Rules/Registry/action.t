use strict;
use warnings;

use Test::More;
use Test::Fatal qw( lives_ok exception );

use BOM::Rules::Registry qw(rule);
use BOM::Rules::Registry::Action;

my @rule_args;
my $rule1 = rule(
    'rule1' => {
        code => sub { push @rule_args, @_; }
    });

my $rule2 = rule(
    'rule2' => {
        code => sub { push @rule_args, @_; }
    });

my $failing_rule1 = rule(
    'failing_rule1' => {
        code => sub { push @rule_args, @_; die +{code => 'Something went wrong on rule 1'} }
    });

my $failing_rule2 = rule(
    'failing_rule2' => {
        code => sub { push @rule_args, @_; die +{code => 'Something went wrong on rule 2'} }
    });

my %args = (
    name        => 'test_rule',
    description => 'A rule for testing',
    category    => 'test',
    rule_set    => [$rule1, $rule2]);

subtest 'object instantiation' => sub {
    my $action = BOM::Rules::Registry::Action->new(%args);

    is_deeply $action, \%args, "New object's properties are correct";
};

subtest 'Verification' => sub {
    my $context = BOM::Rules::Context->new();
    my $action  = BOM::Rules::Registry::Action->new(%args);

    undef @rule_args;
    ok $action->verify, 'Correct success value is returned';
    is_deeply \@rule_args, [$rule1, undef, undef, $rule2, undef, undef], 'Rule codes are invoked with empty context and args';

    undef @rule_args;
    ok $action->verify($context, 'args'), 'Success retrun value';
    is_deeply \@rule_args, [$rule1, $context, 'args', $rule2, $context, 'args'], 'Context and args are correctly passed to rule codes';

    $context = BOM::Rules::Context->new({stop_on_failure => 0});

    my $result = undef;

    undef @rule_args;
    lives_ok { $result = $action->verify($context, 'args') } 'Success retrun value';
    is ref $result, 'BOM::Rules::Result', 'the reference type is correct';
    is_deeply \@rule_args, [$rule1, $context, 'args', $rule2, $context, 'args'], 'Context and args are correctly passed to rule codes';
    is_deeply $result->failed_rules, {}, 'failed rules are same as expectation';
    is_deeply $result->passed_rules, ['rule1', 'rule2'], 'passed rules are same as expectation';
    is $result->has_failure, 0, 'has not failures same as expectation';

    $context = BOM::Rules::Context->new({stop_on_failure => 1});

    undef @rule_args;
    push $action->{rule_set}->@*, $failing_rule1;
    isa_ok exception { $action->verify($context, 'args') }, 'HASH', 'Rule exception';
    is_deeply \@rule_args, [$rule1, $context, 'args', $rule2, $context, 'args', $failing_rule1, $context, 'args'],
        'Context and args are correctly passed to rule codes';

    $context = BOM::Rules::Context->new({stop_on_failure => 0});

    undef @rule_args;
    push $action->{rule_set}->@*, $failing_rule2;
    lives_ok { $result = $action->verify($context, 'args') } 'Rule exception is not handled verification code';
    is ref $result, 'BOM::Rules::Result', 'the reference type is correct';
    is_deeply \@rule_args, [$rule1, $context, 'args', $rule2, $context, 'args', $failing_rule1, $context, 'args', $failing_rule2, $context, 'args'],
        'Context and args are correctly passed to rule codes';
    is_deeply $result->failed_rules,
        {
        'failing_rule1' => +{code => "Something went wrong on rule 1"},
        'failing_rule2' => +{code => "Something went wrong on rule 2"},
        },
        'failed rules are as expectation';
    is_deeply $result->passed_rules, ['rule1', 'rule2'], 'passed rules are as expectation';
    is $result->has_failure, 1, 'has failure as expectation';
};

done_testing();
