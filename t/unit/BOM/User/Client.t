use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;
use Test::MockTime qw( :all );
use Scalar::Util   qw(refaddr);

use BOM::User::Client;
use LandingCompany;

# This is sample value. In production it depends on country residence
use constant MAX_AGE => 18;

my $client;
my $mock_client = Test::MockModule->new('BOM::User::Client');
$mock_client->mock(
    'required_fields',
    sub {
        return qw/date_of_birth first_name last_name/;
    });

$mock_client->mock(
    'landing_company',
    sub {
        my $self = shift;
        if ($self->broker eq 'CR') {
            return bless({'short' => 'svg'}, 'LandingCompany');
        } elsif ($self->broker eq 'MF') {
            return bless({'short' => 'maltainvest'}, 'LandingCompany');
        }
    });

subtest validate_common_account_details => sub {
    $client = BOM::User::Client->rnew;
    $client->broker('CR');
    $client->address_postcode('test address');
    $client->is_virtual(0);
    $client->residence('id');

    subtest 'date of birth validation' => sub {
        my $date_of_birth = 'string';
        my $args          = {'date_of_birth' => $date_of_birth};
        is $client->validate_common_account_details($args)->{error}, 'InvalidDateOfBirth', 'invalid string of date of birth';

        $date_of_birth = '2007-May-13';
        $args          = {'date_of_birth' => $date_of_birth};
        is $client->validate_common_account_details($args)->{error}, 'InvalidDateOfBirth', 'invalid format yyyy-mmm-dd of date of birth';

        $date_of_birth = '2000-04-22';
        $args          = {'date_of_birth' => $date_of_birth};
        is $client->validate_common_account_details($args), undef, 'valid format yyyy-mm-dd of date of birth';

        $date_of_birth = '22-07-2002';
        $args          = {'date_of_birth' => $date_of_birth};
        is $client->validate_common_account_details($args), undef, 'valid format dd-mm-yyyy of date of birth';
    };

    subtest 'minimum age validation' => sub {
        my $max_year = MAX_AGE . 'y';
        Test::MockTime::set_absolute_time('2021-03-06T00:00:00Z');
        my $time = time;

        my $one_day        = 86400;
        my $one_day_before = $time - $one_day;
        my $one_day_older  = Date::Utility->new($one_day_before)->minus_time_interval($max_year)->datetime_ddmmmyy_hhmmss;
        my $args           = {'date_of_birth' => $one_day_older};
        is $client->validate_common_account_details($args), undef, 'younger than required age';

        my $exact_age = Date::Utility->new($time)->minus_time_interval($max_year)->datetime_ddmmmyy_hhmmss;
        $args = {'date_of_birth' => $exact_age};
        is $client->validate_common_account_details($args), undef, 'exact day';

        my $one_day_after   = $time + $one_day;
        my $one_day_younger = Date::Utility->new($one_day_after)->minus_time_interval($max_year)->datetime_ddmmmyy_hhmmss;
        $args = {'date_of_birth' => $one_day_younger};
        is $client->validate_common_account_details($args)->{error}, 'BelowMinimumAge', 'older than required age';
    };

    subtest 'secret question answer validation' => sub {
        my $args = {
            'secret_question' => 'what is your favorite city?',
            'secret_answer'   => ''
        };
        is $client->validate_common_account_details($args)->{error}, 'NeedBothSecret', 'empty secret answer';
        $args = {
            'secret_question' => '',
            'secret_answer'   => 'sg'
        };
        is $client->validate_common_account_details($args)->{error}, 'NeedBothSecret', 'empty secret question';
        $args = {
            'secret_question'  => 'what is your favorite city?',
            'secret_answer'    => 'sg',
            'address_postcode' => 'test address'
        };
        is $client->validate_common_account_details($args), undef, 'not empty secret answer';
    };

    subtest 'place of birth' => sub {
        my $args = {'place_of_birth' => 'svg'};
        is $client->validate_common_account_details($args)->{error}, 'InvalidPlaceOfBirth', 'invalid birth place';

        $args = {'place_of_birth' => 'Japan'};
        is $client->validate_common_account_details($args)->{error}, 'InvalidPlaceOfBirth', 'invalid birth place';

        $args = {
            'place_of_birth'   => 'jp',
            'address_postcode' => 'test address'
        };
        is $client->validate_common_account_details($args), undef, 'valid birth place';
    };

    subtest 'promo code' => sub {
        my $args = {
            'promo_code_status' => 'claimed',
            'promo_code'        => ''
        };
        is $client->validate_common_account_details($args)->{error}, 'No promotion code was provided', 'promo code missing';

        $args = {
            'promo_code_status' => 'claimed',
            'promo_code'        => 'PROMO1'
        };
        is $client->validate_common_account_details($args), undef, 'Promo code status and promo code provided';
    };

    subtest 'Required fields validation' => sub {
        my $args = {
            'first_name' => '',
            'last_name'  => ' \t \r'
        };
        is $client->validate_common_account_details($args)->{error}, 'InputValidationFailed', 'required field check';

        $args = {
            'first_name' => '',
            'last_name'  => 'roy'
        };
        is $client->validate_common_account_details($args)->{error}, 'InputValidationFailed', 'required field check';

        $args = {
            'first_name' => 'test user',
            'last_name'  => 'roy'
        };
        is $client->validate_common_account_details($args), undef, 'required field check';
    };

    subtest 'non pep time' => sub {
        Test::MockTime::set_absolute_time('2021-03-05T00:00:00Z');
        my $time = time;

        my $args = {'non_pep_declaration_time' => 'text'};
        is $client->validate_common_account_details($args)->{error}, 'InvalidNonPepTime', 'invalid string of non pep time';

        $args = {'non_pep_declaration_time' => '2019-03-20'};
        is $client->validate_common_account_details($args), undef, 'valid date format of non pep time';

        $args = {'non_pep_declaration_time' => $time};
        is $client->validate_common_account_details($args), undef, 'valid time format of non pep time';

        $args = {'non_pep_declaration_time' => '2200-03-20'};
        is $client->validate_common_account_details($args)->{error}, 'TooLateNonPepTime', 'too late non pep time';
    };

    subtest 'fatca time' => sub {
        Test::MockTime::set_absolute_time('2021-03-05T00:00:00Z');
        my $time = time;

        my $args = {'fatca_declaration_time' => 'text'};
        is $client->validate_common_account_details($args)->{error}, 'InvalidFatcaTime', 'invalid string of FATCA time';
        throws_ok { $client->_validate_fatca_time($args->{fatca_declaration_time}) } qr/InvalidFatcaTime/,
            'invalid string of FATCA time - throws correctly';

        $args = {'fatca_declaration_time' => '2019-03-20'};
        is $client->validate_common_account_details($args),                undef, 'valid date format of FATCA time';
        is $client->_validate_fatca_time($args->{fatca_declaration_time}), undef, 'valid date format of FATCA time - Direct sub call';

        $args = {'fatca_declaration_time' => $time};
        is $client->validate_common_account_details($args),                undef, 'valid time format of FATCA time';
        is $client->_validate_fatca_time($args->{fatca_declaration_time}), undef, 'valid time format of FATCA time - Direct sub call';

        $args = {'fatca_declaration_time' => '2200-03-20'};
        is $client->validate_common_account_details($args)->{error}, 'TooLateFatcaTime', 'too late FATCA time';
        throws_ok { $client->_validate_fatca_time($args->{fatca_declaration_time}) } qr/TooLateFatcaTime/, 'too late FATCA time - throws correctly';
    };

    subtest 'po box validation' => sub {
        my $args = {
            'address_line_1' => 'ring road',
            'address_line_2' => 'p.o box: 123'
        };
        is $client->validate_common_account_details($args), undef, 'CR - svg not validated';

        $client->broker('MF');
        is $client->validate_common_account_details($args)->{error}, 'PoBoxInAddress', 'MF - maltainvest validated';

        $args = {
            'address_line_1' => 'ring road',
            'address_line_2' => 'po box: 123'
        };
        is $client->validate_common_account_details($args), undef, 'valid address';

        $mock_client->unmock_all();
    };

    subtest 'forbidden post codes' => sub {
        my $client = BOM::User::Client->rnew;
        $client->broker('MX');
        $client->is_virtual(0);
        $client->residence('gb');

        my $forbidden_postcode_pattern;

        my $mock_country = Test::MockModule->new('Brands::Countries');
        $mock_country->mock(
            'countries_list',
            sub {
                return {
                    'gb' => {
                        forbidden_postcode_pattern => $forbidden_postcode_pattern,
                    }};
            });

        my $tests = [{
                postcode => 'JE10',
                pattern  => qr/(.*)/,
                error    => 'ForbiddenPostcode',
            },
            {
                postcode => 'JE10',
                pattern  => qr/^JE.*$/,
                error    => 'ForbiddenPostcode',
            },
            {
                postcode => 'JE10',
                pattern  => undef,
                error    => undef,
            },
            {
                postcode => 'JE3',
                pattern  => qr/^JE\d+$/,
                error    => 'ForbiddenPostcode',
            },
            {
                postcode => 'JE',
                pattern  => qr/^JE\d+$/,
                error    => undef,
            },
            {
                postcode => 'JE',
                pattern  => qr/^JE/,
                error    => 'ForbiddenPostcode',
            },
        ];

        my $args = {};

        for my $test ($tests->@*) {
            $args->{address_postcode} = $test->{postcode};
            $forbidden_postcode_pattern = $test->{pattern};

            if (my $error = $test->{error}) {
                ok $client->validate_common_account_details($args)->{error} =~ /^$error/, "error: $error";
            } else {
                is $client->validate_common_account_details($args), undef, 'valid postcode';
            }
        }
    };
};

subtest 'duplicate_sibling_from_vr' => sub {
    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $date_joined = {};

    $client_mock->mock(
        'date_joined',
        sub {
            my ($cli) = @_;

            return $date_joined->{$cli->loginid} // '2020-10-10 10:10:10';
        });

    my $user_mock = Test::MockModule->new('BOM::User');
    $user_mock->mock(
        'new',
        sub {
            return bless({}, 'BOM::User');
        });

    my $user        = BOM::User->new;
    my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
    my $duplicate_account;
    my @siblings;

    $status_mock->mock(
        'duplicate_account',
        sub {
            return $duplicate_account;
        });

    $user_mock->mock(
        'clients',
        sub {
            return @siblings;
        });

    $client_mock->mock(
        'status',
        sub {
            return bless +{}, 'BOM::User::Client::Status';
        });

    my $client = BOM::User::Client->rnew;
    $client->user($user);
    $client->loginid('CLI001');

    $client->broker('MX');
    $client->residence('gb');

    is $client->duplicate_sibling_from_vr, undef, 'No siblings from a real client';

    $client->broker('VRTC');

    is $client->duplicate_sibling_from_vr, undef, 'No siblings from a vr client wihtout siblings';

    my $sibling = BOM::User::Client->rnew;
    $sibling->loginid('SIB001');
    push @siblings, $sibling;
    $sibling->broker('VRTC');
    $sibling->residence('gb');

    $client->broker('CR');

    is $client->duplicate_sibling_from_vr, undef, 'No siblings from a real client';

    $client->broker('VRTC');

    is $client->duplicate_sibling_from_vr, undef, 'No siblings from a vr client wihtout real siblings';

    $sibling->broker('MX');
    is $client->duplicate_sibling_from_vr, undef, 'No siblings from a vr client wihtout real duplicated siblings';

    $duplicate_account = {
        staff  => 'test',
        reason => 'any reason'
    };

    is $client->duplicate_sibling_from_vr, undef, 'No siblings for any reason';

    $duplicate_account = {
        staff  => 'test',
        reason => 'Duplicate account - currency change'
    };

    is refaddr($client->duplicate_sibling_from_vr), refaddr($sibling), 'Got a duplicated sibling';

    my $sibling2 = BOM::User::Client->rnew;
    $sibling2->loginid('SIB002');
    push @siblings, $sibling2;
    $sibling2->broker('MX');
    $sibling2->residence('gb');

    $sibling->broker('VRTC');
    is refaddr($client->duplicate_sibling_from_vr), refaddr($sibling2), 'Got a duplicated sibling';

    # make sibling date joined the most future
    $sibling->broker('MX');
    $date_joined->{SIB001} = '2030-10-10 10:10:10';
    ok(Date::Utility->new($sibling->date_joined)->epoch > Date::Utility->new($sibling2->date_joined)->epoch, 'Expected date joined comparison');
    is refaddr($client->duplicate_sibling_from_vr), refaddr($sibling), 'Got a duplicated sibling';

    # revert the dates
    $sibling->broker('MX');
    $date_joined->{SIB002} = '2040-10-10 10:10:10';
    ok(Date::Utility->new($sibling->date_joined)->epoch < Date::Utility->new($sibling2->date_joined)->epoch, 'Expected date joined comparison');
    is refaddr($client->duplicate_sibling_from_vr), refaddr($sibling2), 'Got a duplicated sibling';

    # give sibling1 landing company = mf
    $sibling->broker('MF');
    is refaddr($client->duplicate_sibling_from_vr), refaddr($sibling), 'Got a duplicated sibling which is MF (higher prio)';

    $user_mock->unmock_all;
    $status_mock->unmock_all;
    $client_mock->unmock_all;
};

subtest 'duplicate_sibling' => sub {
    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $date_joined = {};

    $client_mock->mock(
        'date_joined',
        sub {
            my ($cli) = @_;

            return $date_joined->{$cli->loginid} // '2020-10-10 10:10:10';
        });

    my $user_mock = Test::MockModule->new('BOM::User');
    $user_mock->mock(
        'new',
        sub {
            return bless({}, 'BOM::User');
        });

    my $user        = BOM::User->new;
    my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
    my $duplicate_account;
    my @siblings;

    $status_mock->mock(
        'duplicate_account',
        sub {
            return $duplicate_account;
        });

    $user_mock->mock(
        'clients',
        sub {
            return @siblings;
        });
    $client_mock->mock(
        'status',
        sub {
            return bless +{}, 'BOM::User::Client::Status';
        });

    my $client = BOM::User::Client->rnew;
    $client->user($user);
    $client->loginid('CLI001');

    $client->broker('MX');
    $client->residence('gb');

    is $client->duplicate_sibling, undef, 'No siblings from a vr client wihtout siblings';

    my $sibling = BOM::User::Client->rnew;
    $sibling->loginid('SIB001');
    push @siblings, $sibling;
    $sibling->broker('VRTC');
    $sibling->residence('gb');

    is $client->duplicate_sibling, undef, 'No siblings from a vr client wihtout real siblings';
    $sibling->broker('MX');
    is $client->duplicate_sibling, undef, 'No siblings from a vr client wihtout real duplicated siblings';

    $duplicate_account = {
        staff  => 'test',
        reason => 'any reason'
    };

    is $client->duplicate_sibling, undef, 'No siblings for any reason';

    $duplicate_account = {
        staff  => 'test',
        reason => 'Duplicate account - currency change'
    };

    is refaddr($client->duplicate_sibling), refaddr($sibling), 'Got a duplicated sibling';

    my $sibling2 = BOM::User::Client->rnew;
    $sibling2->loginid('SIB002');
    push @siblings, $sibling2;
    $sibling2->broker('MX');
    $sibling2->residence('gb');

    $sibling->broker('VRTC');
    is refaddr($client->duplicate_sibling), refaddr($sibling2), 'Got a duplicated sibling';

    # make sibling date joined the most future
    $sibling->broker('MX');
    $date_joined->{SIB001} = '2030-10-10 10:10:10';
    ok(Date::Utility->new($sibling->date_joined)->epoch > Date::Utility->new($sibling2->date_joined)->epoch, 'Expected date joined comparison');
    is refaddr($client->duplicate_sibling), refaddr($sibling), 'Got a duplicated sibling';

    # revert the dates
    $sibling->broker('MX');
    $date_joined->{SIB002} = '2040-10-10 10:10:10';
    ok(Date::Utility->new($sibling->date_joined)->epoch < Date::Utility->new($sibling2->date_joined)->epoch, 'Expected date joined comparison');
    is refaddr($client->duplicate_sibling), refaddr($sibling2), 'Got a duplicated sibling';

    # give sibling1 landing company = mf
    $sibling->broker('MF');
    is refaddr($client->duplicate_sibling), refaddr($sibling), 'Got a duplicated sibling which is MF (higher prio)';

    $user_mock->unmock_all;
    $status_mock->unmock_all;
    $client_mock->unmock_all;
};

done_testing;
