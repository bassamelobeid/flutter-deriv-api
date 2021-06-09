use strict;
use warnings;

use Test::Fatal qw( lives_ok );
use Test::More;

use BOM::Rules::Result;

subtest 'object initialization' => sub {
    my $result;

    lives_ok { $result = BOM::Rules::Result->new() } 'object created successfully';
    is $result->has_failure, 0, 'initial value is correct for `has_failure`';
    is_deeply $result->passed_rules, [], 'initial value is correct for `passed_rules`';
    is_deeply $result->failed_rules, {}, 'initial value is correct for `failed_rules`';
    is_deeply $result->errors,       {}, 'initial value is correct for `errors`';
};

subtest 'append_failure' => sub {
    my $result = BOM::Rules::Result->new();

    lives_ok { $result->append_failure('rule 1', {code => 'ErrorCode1'}) } 'failure 1 appended';
    is $result->has_failure, 1, 'has_failure value changed to 1 correctly';
    is_deeply $result->failed_rules, {'rule 1' => {code => 'ErrorCode1'}}, 'failed_rule is updated correctly';
    is_deeply $result->errors, {'ErrorCode1' => 1}, 'errors array has updated correctly';
    is_deeply $result->passed_rules, [], 'passed_rules is empty as expectation';

    lives_ok { $result->append_failure('rule 2', {code => 'ErrorCode2', other => 'value'}) } 'failure 2 appended';
    is $result->has_failure, 1, 'has_failure is still 1 correctly';
    is_deeply $result->failed_rules,
        {
        'rule 1' => {code => 'ErrorCode1'},
        'rule 2' => {
            code  => 'ErrorCode2',
            other => 'value'
        },
        },
        'failed_rule is updated correctly';
    is_deeply $result->errors,
        {
        ErrorCode1 => 1,
        ErrorCode2 => 1
        },
        'errors array has updated correctly';
    is_deeply $result->passed_rules, [], 'passed_rules is empty as expectation';
};

subtest 'append_success' => sub {
    my $result = BOM::Rules::Result->new();

    lives_ok { $result->append_success('rule 1') } 'success 1 appended';
    is $result->has_failure, 0, 'has_failure not changed correctly';
    is_deeply $result->failed_rules, {}, 'failed_rule is empty correctly';
    is_deeply $result->errors,       {}, 'errors is empty correctly';
    is_deeply $result->passed_rules, ['rule 1'], 'passed_rules is updated as expectation';

    lives_ok { $result->append_success('rule 2') } 'failure 2 appended';
    is $result->has_failure, 0, 'has_failure is still 0 correctly';
    is_deeply $result->failed_rules, {}, 'failed_rule is not updated correctly';
    is_deeply $result->errors,       {}, 'errors has not updated correctly';
    is_deeply $result->passed_rules, ['rule 1', 'rule 2'], 'new value is appended to passed_rules as expectation';
};

subtest 'merge test 1' => sub {
    my $result_merged = BOM::Rules::Result->new();

    my $result_1 = BOM::Rules::Result->new();
    lives_ok { $result_1->append_failure('rule 1', {code => 'ErrorCode1'}) } 'failure 1 appended';
    lives_ok { $result_1->append_success('rule 1') } 'success 1 appended';
    lives_ok { $result_1->append_failure('rule 2', {code => 'ErrorCode2'}) } 'failure 2 appended';

    my $result_2 = BOM::Rules::Result->new();
    lives_ok { $result_2->append_success('rule 2') } 'success 2 appended';
    lives_ok { $result_2->append_failure('rule 3', {code => 'ErrorCode3'}) } 'failure 3 appended';

    $result_merged->merge($result_1);
    $result_merged->merge($result_2);

    is $result_merged->has_failure, 1, 'has_failure is 1 correctly';
    is_deeply $result_merged->failed_rules,
        {
        'rule 1' => {code => 'ErrorCode1'},
        'rule 2' => {code => 'ErrorCode2'},
        'rule 3' => {code => 'ErrorCode3'},
        },
        'failed_rule values are correct';
    is_deeply $result_merged->errors,
        {
        ErrorCode1 => 1,
        ErrorCode2 => 1,
        ErrorCode3 => 1
        },
        'errors values are correct';
    is_deeply $result_merged->passed_rules, ['rule 1', 'rule 2'], 'passed_rules values are correct';
};

subtest 'merge test 2' => sub {
    my $result_merged = BOM::Rules::Result->new();

    my $result_1 = BOM::Rules::Result->new();
    lives_ok { $result_1->append_success('rule 1') } 'success 1 appended';

    my $result_2 = BOM::Rules::Result->new();
    lives_ok { $result_2->append_failure('rule 1', {code => 'ErrorCode1', other => 'value'}) } 'failure 1 appended';

    my $result_3 = BOM::Rules::Result->new();
    lives_ok { $result_3->append_success('rule 2') } 'failure 2 appended';

    $result_merged->merge($result_1);
    $result_merged->merge($result_2);
    $result_merged->merge($result_3);

    is $result_merged->has_failure, 1, 'has_failure is 1 correctly';
    is_deeply $result_merged->failed_rules,
        {
        'rule 1' => {
            code  => 'ErrorCode1',
            other => 'value'
        },
        },
        'failed_rule values are correct';
    is_deeply $result_merged->errors, {ErrorCode1 => 1}, 'errors values are correct';
    is_deeply $result_merged->passed_rules, ['rule 1', 'rule 2'], 'passed_rules values are correct';
};

subtest 'merge test 3' => sub {
    my $result_merged = BOM::Rules::Result->new();

    my $result_1 = BOM::Rules::Result->new();
    lives_ok { $result_1->append_success('rule 1') } 'success 1 appended';

    my $result_2 = BOM::Rules::Result->new();
    lives_ok { $result_2->append_success('rule 2') } 'success 2 appended';

    my $result_3 = BOM::Rules::Result->new();
    lives_ok { $result_3->append_success('rule 3') } 'failure 3 appended';

    my $result_4 = BOM::Rules::Result->new();
    lives_ok { $result_4->append_success('rule 4') } 'failure 4 appended';

    $result_merged->merge($result_1);
    $result_merged->merge($result_2);
    $result_merged->merge($result_3);
    $result_merged->merge($result_4);

    is $result_merged->has_failure, 0, 'has_failure is 0 correctly';
    is_deeply $result_merged->failed_rules, {}, 'failed_rule is empty correctly';
    is_deeply $result_merged->errors,       {}, 'errors is empty correctly';
    is_deeply $result_merged->passed_rules, ['rule 1', 'rule 2', 'rule 3', 'rule 4'], 'passed_rules values are correct';
};

done_testing();
