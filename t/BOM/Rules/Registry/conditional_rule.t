use strict;
use warnings;

use Test::More;
use Test::Fatal;

use BOM::Rules::Registry::Rule::Conditional;
use BOM::Rules::Registry qw(rule);
use BOM::Rules::Context;

my $context = BOM::Rules::Context->new(landing_company => 'cr');

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
        args_key        => 'arg1',
        rules_per_value => {});
    my $rule = BOM::Rules::Registry::Rule::Conditional->new(%args);
    is_deeply $rule, \%args, 'Rule content is corerect';
    like exception { $rule->apply($context) }, qr/This rule cannot be applied with empy action args/,
        'Action args are required for this kind of rule';
    like exception { is_deeply $rule->apply(undef, {arg1 => 1}) }, qr/The key-value 'arg1=1' doesn't match any configured condition/,
        'Empty rules_per_value will cause failure';

    %args = (
        args_key        => 'arg1',
        rules_per_value => {'value1' => [$rule1]});
    $rule = BOM::Rules::Registry::Rule::Conditional->new(%args);
    is_deeply $rule, \%args, 'Rule content is corerect';
    like exception { $rule->apply($context, {}) }, qr/The key-value 'arg1=' doesn't match any configured condition/,
        'Correct exception if the configured action arg is missing';
    like exception { $rule->apply($context, {arg1 => 'dummy'}) }, qr/The key-value 'arg1=dummy' doesn't match any configured condition/,
        'Correct exception for unsupported value';

    is scalar @call_args, 0, 'No rule is applied yet';
    $rule->{rules_per_value}->{'default'} = [$rule2];
    ok $rule->apply($context, {}), 'Rule applied successfully';
    is_deeply \@call_args, [$rule2, $context, {}], 'The default rule set configured for empty arg is applied';

    undef @call_args;
    ok $rule->apply($context, {arg1 => 'value1'}), 'Rule applied successfully';
    is_deeply \@call_args, [$rule1, $context, {arg1 => 'value1'}], 'The matching rule set is invoked';

    undef @call_args;
    %args = (
        args_key        => 'arg1',
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
        context_key     => 'residence',
        rules_per_value => {});
    my $rule = BOM::Rules::Registry::Rule::Conditional->new(%args);
    is_deeply $rule, \%args, 'Rule content is corerect';
    like exception { $rule->apply() }, qr/This rule cannot be applied with empy context/, 'Action args are required for this kind of rule';
    like exception { is_deeply $rule->apply($context) }, qr/The key-value 'residence=' doesn't match any configured condition/,
        'Empty rules_per_value will cause failure';

    %args = (
        context_key     => 'residence',
        rules_per_value => {'de' => [$rule1]});
    $rule = BOM::Rules::Registry::Rule::Conditional->new(%args);
    is_deeply $rule, \%args, 'Rule content is corerect';
    like exception { $rule->apply($context) }, qr/The key-value 'residence=' doesn't match any configured condition/,
        'Correct exception if the configured context key is empty';

    $context->{residence} = 'nowhere';
    like exception { $rule->apply($context) }, qr/The key-value 'residence=nowhere' doesn't match any configured condition/,
        'Correct exception for unsupported value';

    is scalar @call_args, 0, 'No rule is applied yet';
    $rule->{rules_per_value}->{'default'} = [$rule2];
    ok $rule->apply($context, {}), 'Rule applied successfully';
    is_deeply \@call_args, [$rule2, $context, {}], 'The default rule set for missing value is applied';

    undef @call_args;
    $context->{residence} = 'de';
    ok $rule->apply($context), 'Rule applied successfully';
    is_deeply \@call_args, [$rule1, $context, undef], 'The matching rule set is invoked';

    undef @call_args;
    %args = (
        context_key     => 'residence',
        rules_per_value => {
            'de'      => $rule1,
            'default' => $rule2
        });
    $rule = BOM::Rules::Registry::Rule::Conditional->new(%args);
    $context->{residence} = 'nowhere';
    ok $rule->apply($context), 'Rule applied successfully';
    is_deeply \@call_args, [$rule2, $context, undef], 'The unsuppoorted value is defaulted to the wildcard case';

};

done_testing();
