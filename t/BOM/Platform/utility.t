use strict;
use warnings;

use Test::Deep;
use Test::More;
use Test::MockModule;

use BOM::Platform::Utility;

subtest 'hash_to_array' => sub {
    subtest 'simple hash' => sub {
        my $input = {
            a => '1',
            b => {
                c => '2',
                d => '3',
            },
        };

        my @expected_output = ('1', '2', '3');
        my $output          = BOM::Platform::Utility::hash_to_array($input);

        cmp_bag $output, \@expected_output, "simple hash is OK";
    };

    subtest 'simple hash of arrays' => sub {
        my $input = {
            a => ['1', '2', '3'],
            b => {
                c => ['4', '5', '6'],
                d => ['7', '8', '9'],
            },
        };

        my @expected_output = ('1', '2', '3', '4', '5', '6', '7', '8', '9');
        my $output          = BOM::Platform::Utility::hash_to_array($input);

        cmp_bag $output, \@expected_output, "simple hash of arrays is OK";
    };

    subtest 'complex hash' => sub {
        my $input = {
            # hash of array
            a => ['1', '2', '3'],
            # nested hash of arrays
            b => {
                a => ['x', 'y', 'z'],    # redundant key 'a'
                c => ['4', '5', '6'],
                d => ['7', '8', '9'],
            },
            # hash of array of hashes
            z => [{
                    x => ['f'],
                    y => ['g'],
                }
            ],
            # simple hash
            q => 't',
        };

        my @expected_output = ('1', '2', '3', '4', '5', '6', '7', '8', '9', 'f', 'g', 't', 'x', 'y', 'z');
        my $output          = BOM::Platform::Utility::hash_to_array($input);

        cmp_bag $output, \@expected_output, "complex hash is OK";
    };
};

done_testing;
