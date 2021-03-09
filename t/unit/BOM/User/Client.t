use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;
use Test::MockTime qw( :all );

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
};

done_testing;
