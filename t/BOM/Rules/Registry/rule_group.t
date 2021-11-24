use strict;
use warnings;
no indirect;

use Test::Most;
use Test::Fatal;

use BOM::Rules::Registry::Rule::Group;
use BOM::Rules::Registry qw(rule);
use BOM::Rules::Context;

my @call_args;

my $rule1 = rule(
    'rule1' => {
        code => sub { push @call_args, @_; return 'result 1'; }
    });
my $rule2 = rule(
    'rule2' => {
        code => sub { push @call_args, @_; return 'result 2'; }
    });

my $failing_rule = rule(
    'failing' => {
        code => sub { push @call_args, @_; shift->fail('Something went wrong') }
    });

my %args;

subtest 'Argument mapping' => sub {
    my $context = BOM::Rules::Context->new();
    undef @call_args;

    %args = (
        required_arguments => [qw/a b/],
        argument_mapping   => {},
        ruleset            => [$rule1],
    );
    my $rule = BOM::Rules::Registry::Rule::Group->new(%args);

    like exception { $rule->apply($context) }, qr/No value found for required argument 'a'/, 'Argument mapping is required';

    # literals
    $args{argument_mapping} = {
        a => "'literal 1'",
        b => "'literal 2'"
    };
    $rule = BOM::Rules::Registry::Rule::Group->new(%args);
    lives_ok { $rule->apply($context) } 'Rules are applied successfully';
    is_deeply \@call_args,
        [
        $rule1, $context,
        {
            a => 'literal 1',
            b => 'literal 2'
        }
        ],
        'Arguments are correctly mapped to literals';
    undef @call_args;

    # from action args
    $args{argument_mapping} = {
        a => "x",
        b => "y"
    };
    my $action_args = {
        x => 10,
        y => 11,
        a => 12,
        b => 13
    };
    $rule = BOM::Rules::Registry::Rule::Group->new(%args);
    lives_ok { $rule->apply($context, $action_args) } 'Rules are applied successfully';
    is_deeply \@call_args,
        [
        $rule1, $context,
        {
            a => 10,
            b => 11,
            x => 10,
            y => 11
        }
        ],
        'Arguments are correctly trannslated from action args + action args';
    undef @call_args;
};

subtest 'Ruleset' => sub {
    my $context = BOM::Rules::Context->new(stop_on_failure => 0);
    my $result;

    %args = (
        required_arguments => [qw/a b/],
        argument_mapping   => {
            a => "'1'",
            b => "'2'"
        },
        ruleset => [$rule1, $rule2],
    );
    my $rule = BOM::Rules::Registry::Rule::Group->new(%args);
    lives_ok { $result = $rule->apply($context) } 'Rule is applied successfully';
    is_deeply $result,
        {
        errors       => {},
        has_failure  => 0,
        failed_rules => [],
        passed_rules => ['rule1', 'rule2']
        },
        'Groupped rules are applied in correct order';

    $args{ruleset} = [$rule1, $failing_rule];
    $rule = BOM::Rules::Registry::Rule::Group->new(%args);
    lives_ok { $result = $rule->apply($context) } 'Rule is applied';
    is_deeply $result,
        {
        errors       => {'Something went wrong' => 1},
        has_failure  => 1,
        failed_rules => [{
                rule       => 'failing',
                error_code => 'Something went wrong'
            }
        ],
        passed_rules => ['rule1']
        },
        'passing and failing rule appear in the result';

    $context = BOM::Rules::Context->new(stop_on_failure => 1);
    is_deeply exception { $rule->apply($context) },
        {
        rule       => 'failing',
        error_code => 'Something went wrong'
        },
        'Correct exception is thrwn on failure';
};

done_testing();
