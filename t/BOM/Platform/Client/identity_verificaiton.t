use strict;
use warnings;

use Test::Most 'no_plan';
use Test::Deep;
use Date::Utility;

use BOM::Platform::Client::IdentityVerification;

subtest 'is_mute_provider' => sub {
    is BOM::Platform::Client::IdentityVerification::is_mute_provider('abcd'), 0, 'Correct result for invalid provider name';

    is BOM::Platform::Client::IdentityVerification::is_mute_provider('zaig'), 1, 'Zaig is mute at the moment';

    is BOM::Platform::Client::IdentityVerification::is_mute_provider('smile_identity'), 0, 'Small identity is not mute';

};

subtest 'transform_response' => sub {
    my @tests = ({
            provider => 'xyz',
            input    => {
                full_name => 'Sample name',
                FullName  => 'Sample name',
            },
            result  => undef,
            comment => 'Empty result is returned for invalid provider',
        },
        {
            provider => 'smile_identity',
            input    => {
                FullName       => 'Test identity',
                DOB            => '2001-01-01',
                ExpirationDate => '2022-01-10',
                SmileJobID     => '12345',
            },
            result => {
                full_name       => 'Test identity',
                date_of_birth   => '2001-01-01',
                expiration_date => Date::Utility->new('2022-01-10'),
                portal_uri      => 'https://portal.smileidentity.com/partner/job_results/12345',
            },
            comment => 'Correct result for normal smile identity input',
        },
        {
            provider => 'smile_identity',
            input    => {
                FullName       => 'Test identity',
                DOB            => '2001-01-01',
                ExpirationDate => 'invalid date',
                SmileJobID     => '12345',
            },
            result => {
                full_name       => 'Test identity',
                date_of_birth   => '2001-01-01',
                expiration_date => undef,
                portal_uri      => 'https://portal.smileidentity.com/partner/job_results/12345',
            },
            comment => 'Incorrect dob is handled gracefully for smile idenity',
        },
        {
            provider => 'smile_identity',
            input    => {
                FullName       => 'Test identity',
                DOB            => '2001-01-01',
                ExpirationDate => '2022-01-10',
                SmileJobID     => undef,
            },
            result => {
                full_name       => 'Test identity',
                date_of_birth   => '2001-01-01',
                expiration_date => Date::Utility->new('2022-01-10'),
                portal_uri      => undef,
            },
            comment => 'Empty uri params are handled gracefully',
        },
        {
            provider => 'smile_identity',
            input    => {},
            result   => {
                full_name       => undef,
                date_of_birth   => undef,
                expiration_date => undef,
                portal_uri      => undef,
            },
            comment => 'Correct result if smile identity input is empty',
        },
        {
            provider => 'zaig',
            input    => {
                name               => 'Test identity',
                birthdate          => '2001-01-01',
                natural_person_key => 'the_key'
            },
            result => {
                full_name       => 'Test identity',
                date_of_birth   => '2001-01-01',
                expiration_date => undef,
                portal_uri      => 'https://dash.zaig.com.br/natural-person/the_key',
            },
            comment => 'Correct result for normal Zaig input',
        },
        {
            provider => 'zaig',
            input    => {
                name               => 'Test identity',
                birthdate          => '2001-01-01',
                natural_person_key => ''
            },
            result => {
                full_name       => 'Test identity',
                date_of_birth   => '2001-01-01',
                expiration_date => undef,
                portal_uri      => undef,
            },
            comment => 'Correct result for Zaig with empty natural_person_key',
        },
        {
            provider => 'zaig',
            input    => {},
            result   => {
                full_name       => undef,
                date_of_birth   => undef,
                expiration_date => undef,
                portal_uri      => undef,
            },
            comment => 'Empty Zaig input is handled gracefully',
        },
    );

    for my $test (@tests) {
        cmp_deeply BOM::Platform::Client::IdentityVerification::transform_response($test->{provider}, $test->{input}),
            $test->{result}, $test->{comment};
    }
};

done_testing;
