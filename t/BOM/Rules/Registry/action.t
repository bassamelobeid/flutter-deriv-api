use strict;
use warnings;

use Test::More;
use Test::Fatal;

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
my $failing_rule = rule(
    'failing' => {
        code => sub { push @rule_args, @_; die 'Something went wrong' }
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
    my $action = BOM::Rules::Registry::Action->new(%args);

    undef @rule_args;
    ok $action->verify, 'Correct success value is returned';
    is_deeply \@rule_args, [$rule1, undef, undef, $rule2, undef, undef], 'Rule codes are invoked with empty context and args';

    undef @rule_args;
    ok $action->verify('context', 'args'), 'Success retrun value';
    is_deeply \@rule_args, [$rule1, 'context', 'args', $rule2, 'context', 'args'], 'Context and args are correctly passed to rule codes';

    undef @rule_args;
    push $action->{rule_set}->@*, $failing_rule;
    like exception { $action->verify('context', 'args') }, qr/Something went wrong/, 'Rule exception is not handled verification code';
    is_deeply \@rule_args, [$rule1, 'context', 'args', $rule2, 'context', 'args', $failing_rule, 'context', 'args'],
        'Context and args are correctly passed to rule codes';
};

done_testing();
