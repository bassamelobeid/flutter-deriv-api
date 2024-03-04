use strict;
use warnings;

use BOM::Product::Utils qw(beautify_stake);
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

done_testing();
