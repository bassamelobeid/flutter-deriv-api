use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal;

use BOM::Rules::Registry::Rule;
use BOM::Rules::Context;

my %args = (
    name        => 'test_rule',
    description => 'A rule for testing',
    code        => sub { return 'test result' });

my %failing_args = (
    name        => 'test_rule_failing',
    description => 'A rule for testing',
    code        => sub { die +{error_code => "test failed"} });

subtest 'Rule object behaviour when context is not provided' => sub {
    my $rule = BOM::Rules::Registry::Rule->new(%args);

    my @properties = qw/name description category error_code error_message/;

    my $result = $rule->apply(BOM::Rules::Context->new());
    is_deeply $rule, \%args, "New object's properties are correct";
    isa_ok $result, 'BOM::Rules::Result', 'Code is correctly called';
};

subtest 'Rule object behaviour on context provided without stop on failure, and code throw an error ' => sub {
    my $rule = BOM::Rules::Registry::Rule->new(%failing_args);

    my @properties = qw/name description category error_code error_message/;

    my $result;
    $result = $rule->apply(BOM::Rules::Context->new({stop_on_failure => 0}));
    is_deeply $rule, \%failing_args, "New object's properties are correct";
    isa_ok $result, 'BOM::Rules::Result', 'Code is correctly called';
};

subtest 'Rule object behaviour on context provided with stop on failure, and code throw an error ' => sub {
    my $rule = BOM::Rules::Registry::Rule->new(%failing_args);

    my @properties = qw/name description category error_code error_message/;

    my $result;
    isa_ok exception {
        $result = $rule->apply(BOM::Rules::Context->new({stop_on_failure => 1}))
    }, 'HASH', 'Exception thrown';
    is_deeply $rule, \%failing_args, "New object's properties are correct";
};

done_testing();
