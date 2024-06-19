use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Exception;

use BOM::Rules::Registry::Rule::Conditional;
use BOM::Rules::Registry qw(rule);
use BOM::Rules::Context;

my $context = BOM::Rules::Context->new();

my @call_args;

my $rule1 = rule(
    'rule1' => {
        code => sub { push @call_args, @_; }
    });
my $rule2 = rule(
    'rule2' => {
        code => sub { push @call_args, @_; }
    });

my $failing_rule = rule(
    'failing' => {
        code => sub { push @call_args, @_; die 'Something went wrong' }
    });

my %args;

subtest 'Branching on args' => sub {
    undef @call_args;
    %args = (
        key             => 'arg1',
        rules_per_value => {});
    my $rule = BOM::Rules::Registry::Rule::Conditional->new(%args);
    is_deeply $rule, \%args, 'Rule content is corerect';
    like exception { $rule->apply($context) }, qr/This rule cannot be applied with empy action args/,
        'Action args are required for this kind of rule';
    like exception { $rule->apply(undef, {}) }, qr/Invalid context/, 'Empty rules_per_value will cause failure';

    %args = (
        key             => 'arg1',
        rules_per_value => {'value1' => [$rule1]});
    $rule = BOM::Rules::Registry::Rule::Conditional->new(%args);
    is_deeply $rule, \%args, 'Rule content is corerect';
    like exception { $rule->apply($context, {}) }, qr/Condition key 'arg1' was not found in args or context/,
        'Correct exception if the configured action arg is missing';
    lives_ok { $rule->apply($context, {arg1 => 'dummy'}) } 'Missing value passes, if there is no default rule';

    is scalar @call_args, 0, 'No rule is applied yet';
    $rule->{rules_per_value}->{'default'} = [$rule2];
    ok $rule->apply($context, {arg1 => 'dummy'}), 'Rule applied successfully';
    is_deeply \@call_args, [$rule2, $context, {arg1 => 'dummy'}], 'The default rule set configured for empty arg is applied';

    undef @call_args;
    ok $rule->apply($context, {arg1 => 'value1'}), 'Rule applied successfully';
    is_deeply \@call_args, [$rule1, $context, {arg1 => 'value1'}], 'The matching rule set is invoked';

    undef @call_args;
    %args = (
        key             => 'arg1',
        rules_per_value => {
            'value1'  => [$rule1],
            'default' => [$rule2]});
    $rule = BOM::Rules::Registry::Rule::Conditional->new(%args);
    is_deeply $rule, \%args, 'Rule content is corerect';
    ok $rule->apply($context, {arg1 => 'dummy'}), 'Rule applied successfully';
    is_deeply \@call_args, [$rule2, $context, {arg1 => 'dummy'}], 'The unsuppoorted value is defaulted to the wildcard case';
};

subtest 'Branching on context' => sub {
    undef @call_args;
    %args = (
        key             => 'residence',
        rules_per_value => {});
    my $rule = BOM::Rules::Registry::Rule::Conditional->new(%args);
    is_deeply $rule, \%args, 'Rule content is corerect';
    like exception { $rule->apply() }, qr/This rule cannot be applied with empy action args/, 'Action args are required for this kind of rule';

    like exception { is_deeply $rule->apply($context) }, qr/This rule cannot be applied with empy action args/, 'Empty args will cause failure';

    my $action_args = {residence => 'nowhere'};
    %args = (
        key             => 'residence',
        rules_per_value => {'de' => [$rule1]});
    $rule = BOM::Rules::Registry::Rule::Conditional->new(%args);
    is_deeply $rule, \%args, 'Rule content is corerect';
    lives_ok { $rule->apply($context, $action_args) } 'Non-maching value fails, because there is no default rule';

    is scalar @call_args, 0, 'No rule is applied yet';
    $rule->{rules_per_value}->{'default'} = [$rule2];
    ok $rule->apply($context, $action_args), 'Rule applied successfully';
    is_deeply \@call_args, [$rule2, $context, $action_args], 'The default rule set for missing value is applied';

    undef @call_args;
    $action_args->{residence} = 'de';
    ok $rule->apply($context, $action_args), 'Rule applied successfully';
    is_deeply \@call_args, [$rule1, $context, $action_args], 'The matching rule set is invoked';
};

done_testing();
