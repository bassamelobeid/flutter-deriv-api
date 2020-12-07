use strict;
use warnings;

use Test::More;
use Test::Exception;
use BOM::DynamicSettings;

subtest '_validate_tnc_string' => sub {
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

done_testing;
