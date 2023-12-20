use strict;
use warnings;
use utf8;
use Encode;

use Test::More;
use Test::Exception;
use Test::Fatal;
use BOM::DynamicSettings;

subtest 'BOM::DynamicSettings::_validate_tnc_string' => sub {
    subtest 'cannot set a lower version' => sub {
        my @cases = ({
                old    => '{ "binary": "Version 48 2019-05-10", "deriv": "Version 4.2.0 2020-08-07" }',
                new    => '{ "binary": "Version 43 2019-05-10", "deriv": "Version 4.2.0 2020-08-07" }',
                throws => qr/version for binary is lower than previous/,
            },
            {
                old    => '{ "binary": "Version 48 2019-05-10", "deriv": "Version 4.2.0 2020-08-07" }',
                new    => '{ "binary": "Version 48 2019-05-10", "deriv": "Version 4.1.99 2020-08-07" }',
                throws => qr/version for deriv is lower than previous/,
            });

        foreach (@cases) {
            throws_ok {
                BOM::DynamicSettings::_validate_tnc_string($_->{new}, $_->{old});
            }
            $_->{throws}, 'The validation throws the expected message';
        }
    };

    subtest 'setting a higher version' => sub {
        my @cases = ({
                old => '{ "binary": "Version 48 2019-05-10", "deriv": "Version 4.2.0 2020-08-07" }',
                new => '{ "binary": "Version 50 2019-05-10", "deriv": "Version 4.2.0 2020-08-07" }',
            },
            {
                old => '{ "binary": "Version 48 2019-05-10", "deriv": "Version 4.2.0 2020-08-07" }',
                new => '{ "binary": "Version 48 2019-05-10", "deriv": "Version 4.2.1 2020-08-07" }',
            });

        foreach (@cases) {
            lives_ok {
                BOM::DynamicSettings::_validate_tnc_string($_->{new}, $_->{old});
            }
            'The validation passes';
        }
    };

    subtest 'removing a version' => sub {
        my @cases = ({
                old => '{ "binary": "Version 48 2019-05-10", "deriv": "Version 4.2.0 2020-08-07" }',
                new => '{ "deriv": "Version 4.2.0 2020-08-07" }',
            },
            {
                old => '{ "binary": "Version 48 2019-05-10", "deriv": "Version 4.2.0 2020-08-07" }',
                new => '{ "binary": "Version 48 2019-05-10" }',
            });

        foreach (@cases) {
            lives_ok {
                BOM::DynamicSettings::_validate_tnc_string($_->{new}, $_->{old});
            }
            'The validation passes';
        }
    };
};

subtest '_validate_accepted_consonant_names' => sub {
    my @test_cases = ({
            value => [],
            error => undef
        },
        {
            value => [''],
            error => "Invalid keyword '' found."
        },
        {
            value => ['    '],
            error => "Invalid keyword '' found."
        },
        {
            value => [','],
            error => "Invalid keyword ',' found."
        },
        {
            value => ['1234'],
            error => "Invalid keyword '1234' found."
        },
        {
            value => ['bbbb', '1234'],
            error => "Invalid keyword '1234' found."
        },
        {
            value => ['bbbb', '1234'],
            error => "Invalid keyword '1234' found."
        },
        {
            value => ['bbbb'],
            error => undef
        },
        {
            value => ['bbbb', 'cccc'],
            error => undef
        },
    );

    for my $case (@test_cases) {
        my $value = $case->{value};
        my $error = $case->{error};
        if ($error) {
            like exception { BOM::DynamicSettings::_validate_accepted_consonant_names($value) }, qr/$error/;
        } else {
            lives_ok { BOM::DynamicSettings::_validate_accepted_consonant_names($value) };
        }
    }
};

subtest '_validate_currency_pair' => sub {
    my @test_cases = ({
            value => "{}",
            error => "currency_pairs should be a valid key in the json config"
        },
        {
            value => "{\"currency_pairs\":[[\"USD\"]]}",
            error => "is not valid  only two values need to be supplied"
        },
        {
            value => "{\"currency_pairs\":[[\"USD\",\"USD\",\"USD\"]]}",
            error => "is not valid  only two values need to be supplied"
        },
        {
            value => "{\"currency_pairs\":[[\"USD\",\"USD\"]]}",
            error => "both currencies can't have same value"
        },
        {
            value => "{\"currency_pairs\":[[\"ASDASDASD\",\"USD\"]]}",
            error => "is not a valid currency "
        },
        {
            value => "{\"currency_pairs\":[[\"USD\",\"ASDASDASD\"]]}",
            error => "is not a valid currency "
        });
    for my $case (@test_cases) {
        my $value = $case->{value};
        my $error = $case->{error};

        if ($error) {
            like exception { BOM::DynamicSettings::_validate_currency_pair($value) }, qr/$error/, "Correct error for value '$value'";
        } else {
            lives_ok { BOM::DynamicSettings::_validate_currency_pair($value) } "No error for value '$value'";
        }
    }

};

subtest '_validate_corporate_patterns' => sub {
    my @test_cases = ({
            value => [],
            error => undef
        },
        {
            value => [''],
            error => 'No alphabetic character was found.'
        },
        {
            value => [' '],
            error => 'No alphabetic character was found.'
        },
        {
            value => [','],
            error => 'No alphabetic character was found.'
        },
        {
            value => ['1234'],
            error => 'No alphabetic character was found.'
        },
        {
            value => ['.abc'],
            error => 'Each keyword should begin either with an alphabetic character or %'
        },
        {
            value => ['ab%c'],
            error => '% is only allowed at the beginning or the end of a keyword'
        },
        {
            value => ['%'],
            error => 'No alphabetic character was found.'
        },
        {
            value => ['bbbb', 'abc*'],
            error => 'Only alphabetic characters, \. and % \(wildcard\) are allowed'
        },
        {
            value => ['%bbbb'],
            error => undef
        },
        {
            value => ['%bbbb%', 'cccc%', 'درز'],
            error => undef
        },
    );

    for my $case (@test_cases) {
        my $value = $case->{value};
        my $error = $case->{error};

        my $value_str = encode_utf8(join ',', @$value);

        if ($error) {
            like exception { BOM::DynamicSettings::_validate_corporate_patterns($value) }, qr/$error/, "Correct error for value '$value_str'";
        } else {
            lives_ok { BOM::DynamicSettings::_validate_corporate_patterns($value) } "No error for value '$value_str'";
        }
    }
};

done_testing;
