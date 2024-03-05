use strict;
use warnings;

use Test::Most;
use BOM::User::Utility;

my $state_test_data = [{
        state           => undef,
        residence       => undef,
        expected_result => '',
        test_desc       => 'Empty string is returned when residence and state is undef'
    },
    {
        state           => '',
        residence       => '',
        expected_result => '',
        test_desc       => 'Empty string is returned when residence and state is empty'
    },
    {
        state           => 'ba',
        residence       => '',
        expected_result => '',
        test_desc       => 'Empty string is returned when residence is empty and state is present'
    },
    {
        state           => 'bali',
        residence       => 'id',
        expected_result => 'BA',
        test_desc       => 'Long state text bali is converted correctly to BA'
    },
    {
        state           => 'bali',
        residence       => 'au',
        expected_result => '',
        test_desc       => 'Returns empty for combination of bali and au'
    },
    {
        state           => 'baLi',
        residence       => 'Id',
        expected_result => 'BA',
        test_desc       => 'Case is irrelevant, got BA for baLi and Id'
    },
    {
        state           => 'ba',
        residence       => 'Id',
        expected_result => 'BA',
        test_desc       => 'Got value when the state was already a value'
    },
    {
        state           => 'bali',
        residence       => 'au',
        expected_result => '',
        test_desc       => 'Returns empty for combination of bali and au'
    },
    {
        state           => '--Others--',
        residence       => 'id',
        expected_result => '',
        test_desc       => 'Returns empty for combination of incorrect state'
    },
    {
        state           => 'Vienne',
        residence       => 'fr',
        expected_result => '86',
        test_desc       => 'Returns the correct value for fr and Vienne'
    },
    {
        state           => 'Occitanie',
        residence       => 'fr',
        expected_result => 'OCC',
        test_desc       => 'Returns the correct value for fr and Occitanie'
    },
    {
        state           => 'Occitanie',
        residence       => 'invalid',
        expected_result => '',
        test_desc       => 'Returns empty string invalid residence'
    }];

subtest 'Verify the behavior of get_valid_state' => sub {
    for my $state_case ($state_test_data->@*) {
        ok BOM::User::Utility::get_valid_state($state_case->{state}, $state_case->{residence}) eq $state_case->{expected_result},
            $state_case->{test_desc};
    }
};

done_testing();
