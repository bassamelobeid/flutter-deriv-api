use strict;
use warnings;

use BOM::Product::Utils qw(beautify_stake rounddown_to_sig_fig roundup_stake rounddown_stake);
use Test::Exception;
use Test::More;

subtest 'beautify_stake' => sub {
    my @tests = ({
            'name' => 'min stake amount >= 1',
            'args' => {
                'stake_amount' => 15.19,
                'currency'     => 'USD',
                'is_min_stake' => 1
            },
            'expected_result' => '16.00'
        },
        {
            'name' => 'min stake amount < 1',
            'args' => {
                'stake_amount' => 0.04322406,
                'currency'     => 'BTC',
                'is_min_stake' => 1
            },
            'expected_result' => '0.04322500'
        },
        {
            'name' => 'max stake amount >= 1',
            'args' => {
                'stake_amount' => 15.19,
                'currency'     => 'USD',
            },
            'expected_result' => '15.00'
        },
        {
            'name' => 'max stake amount < 1',
            'args' => {
                'stake_amount' => 0.04322406,
                'currency'     => 'BTC',
            },
            'expected_result' => '0.04322400'
        },
    );

    for my $test (@tests) {
        subtest $test->{name} => sub {
            my $result = beautify_stake($test->{args}->{stake_amount}, $test->{args}->{currency}, $test->{args}->{is_min_stake});
            is($result, $test->{expected_result}, 'Stake beautified correctly');
        };
    }
};

subtest 'roundup_stake' => sub {
    is(roundup_stake(5.78190048408128, 2), 5.79,   'roundup_stake(5.7819, 2) = 5.79');
    is(roundup_stake(652.119,          2), 652.12, 'roundup_stake(652.119, 2) = 652.12');
    is(roundup_stake(100,              0), 100,    'roundup_stake(100, 0) = 100');
};

subtest 'rounddown_stake' => sub {

    is(rounddown_stake(652.1193505595861, 2), 652.11, 'rounddown_stake(652.1193505595861, 2) = 652.11');
    is(rounddown_stake(3.14159,           3), 3.141,  'rounddown_stake(3.14159, 3) = 3.141');
    is(rounddown_stake(100,               0), 100,    'rounddown_stake(100, 0) = 100');

};

subtest 'rounddown_to_sig_fig' => sub {

    is(rounddown_to_sig_fig(567,   1), 500,  'rounddown_to_sig_fig(567, 1) = 500');
    is(rounddown_to_sig_fig(1234,  2), 1200, 'rounddown_to_sig_fig(1234, 2) = 1200');
    is(rounddown_to_sig_fig(5,     1), 5,    'rounddown_to_sig_fig(5, 1) = 5');
    is(rounddown_to_sig_fig(0.046, 1), 0.04, 'rounddown_to_sig_fig(0.046, 1) = 0.04');
};

done_testing();
