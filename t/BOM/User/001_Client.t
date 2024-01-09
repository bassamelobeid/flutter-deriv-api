use utf8;
binmode STDOUT, ':utf8';

use strict;
use warnings;

use Test::More qw( no_plan );
use Test::Deep;
use Test::Exception;
use Test::Fatal;
use Test::MockModule;

use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw( create_client );
use BOM::Test::Helper::FinancialAssessment;
use JSON::MaybeUTF8 qw(encode_json_utf8);

use Date::Utility;
use Array::Utils qw(array_minus);
use List::Util   qw(uniq);

my $login_id = 'CR0022';
my $client;

subtest 'initialization' => sub {
    throws_ok {
        BOM::User::Client->new({});
    }
    qr/no loginid/, 'Create instance with empty loginid throws error as expected';

    throws_ok {
        BOM::User::Client->new({loginid => 'cr123'});
    }
    qr/Invalid loginid: cr123/, 'Create instance with lowercase broker code throws error as expected';

    throws_ok {
        BOM::User::Client->new({loginid => '123'});
    }
    qr/Invalid loginid: 123/, 'Create instance with no broker code throws error as expected';

    throws_ok {
        BOM::User::Client->new({loginid => 'FF123'});
    }
    qr/Could not init_db\(\) - No such domain with the broker code FF/, 'Create instance with non-existing broker code throws error as expected';
};

subtest 'Get class by broker code' => sub {
    like exception { BOM::User::Client->get_class_by_broker_code() }, qr/Broker code is missing/, 'Correct error for missing broker code';

    is(BOM::User::Client->get_class_by_broker_code('CRA'),   'BOM::User::Affiliate', 'Correct affiliate class');
    is(BOM::User::Client->get_class_by_broker_code('CRW'),   'BOM::User::Wallet',    'Correct wallet class');
    is(BOM::User::Client->get_class_by_broker_code('CR'),    'BOM::User::Client',    'Correct client class');
    is(BOM::User::Client->get_class_by_broker_code('DUMMY'), 'BOM::User::Client',    'Correct default class');
};

subtest "Client load and saving." => sub {
    plan tests => 48;
    # create client object
    lives_ok { $client = BOM::User::Client->new({'loginid' => $login_id}); }
    "Can create client object 'BOM::User::Client::get_instance({'loginid' => $login_id})'";

    isa_ok($client, 'BOM::User::Client');
    is($client->loginid,    $login_id,                                            'Test $client->loginid');
    is($client->first_name, '†•…‰™œŠŸž€ΑΒΓΔΩαβγδωАБВГДабвгд∀∂∈ℝ∧∪≡∞↑↗↨↻⇣┐┼╔╘░►☺', 'Test $client->first_name');
    is($client->last_name,  '♀ﬁ�⑀₂ἠḂӥẄɐː⍎אԱა Καλημέρα κόσμε, コンニチハ',              'Test $client->last_name');
    is($client->password,   '48elKjgSSiaeD5v233716ab5',                           'Test $client->password');

    $client->first_name('Eric');
    $client->last_name('Clapton');

    $client->save({'clerk' => 'test_suite'});

    is($client->loginid,    $login_id,                  'Test updated $client->loginid');
    is($client->first_name, 'Eric',                     'Test updated $client->first_name');
    is($client->last_name,  'Clapton',                  'Test updated $client->last_name');
    is($client->password,   '48elKjgSSiaeD5v233716ab5', 'Test updated $client->password');

    $client->first_name('Omid');
    $client->last_name('Houshyar');
    $client->save({'clerk' => 'test_suite'});

    lives_ok { $client = BOM::User::Client->new({'loginid' => 'CR0006'}); }
    "Can create client object 'BOM::User::Client::get_instance({'loginid' => CR0006})'";
    ok(!$client->fully_authenticated(), 'CR0006 - not fully authenticated as it has ADDRESS status only');
    $client->set_authentication('ID_NOTARIZED', {status => 'pass'});
    ok($client->fully_authenticated(), 'CR0006 - fully authenticated as it has ID_NOTARIZED');

    lives_ok { $client = BOM::User::Client->new({'loginid' => 'CR0007'}); }
    "Can create client object 'BOM::User::Client::get_instance({'loginid' => CR0007})'";
    is($client->fully_authenticated(), 1, "CR0007 - fully authenticated");

    lives_ok { $client = BOM::User::Client->new({'loginid' => 'CR0008'}); }
    "Can create client object 'BOM::User::Client::get_instance({'loginid' => CR0008})'";
    $client->set_authentication('IDV', {status => 'pass'});
    is($client->fully_authenticated({landing_company => 'bvi'}), 1, "CR0008 - fully authenticated");

    lives_ok { $client = BOM::User::Client->new({'loginid' => 'CR0010'}); }
    "Can create client object 'BOM::User::Client::get_instance({'loginid' => CR0010})'";
    $client->db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare(
                "INSERT INTO betonmarkets.client_authentication_method (client_loginid, authentication_method_code, status) VALUES (?,?,?)");
            $sth->execute($client->loginid, 'ID_ONLINE',   'pending');
            $sth->execute($client->loginid, 'IDV',         'pass');
            $sth->execute($client->loginid, 'ID_DOCUMENT', 'needs_review');
        });
    my $count_authentication_methods = $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT count(*) FROM betonmarkets.client_authentication_method WHERE client_loginid=? GROUP BY client_loginid',
                undef, $client->loginid);
        });
    is($count_authentication_methods->{count},                   4, 'CR0010 - has multiple authentication_methods');
    is($client->fully_authenticated({landing_company => 'bvi'}), 1, "CR0010 - fully authenticated even with multiple authentication methods");

    my $client_details = {
        'loginid'            => 'CR5089',
        'email'              => 'felix@regentmarkets.com',
        'client_password'    => '960f984285701c6d8dba5dc71c35c55c0397ff276b06423146dde88741ddf1af',
        'broker_code'        => 'CR',
        'allow_login'        => 1,
        'last_name'          => 'The cat',
        'first_name'         => 'Felix',
        'date_of_birth'      => '1951-01-01',
        'address_postcode'   => '47650',
        'address_state'      => '',
        'secret_question'    => 'Name of your pet',
        'date_joined'        => '2007-11-29',
        'email'              => 'felix@regentmarkets.com',
        'latest_environment' =>
            '31-May-10 02h09GMT 99.99.99.63 Mozilla 5.0 (X11; U; Linux i686; en-US; rv:1.9.2.3) Gecko 20100401 Firefox 3.6.3 LANG=EN SKIN=',
        'address_city'          => 'Subang Jaya',
        'address_line_1'        => '†•…‰™œŠŸž€ΑΒΓΔΩαβγδωАБВГДабвгд∀∂∈ℝ∧∪≡∞↑↗↨↻⇣┐┼╔╘░►☺',
        'secret_answer'         => '::ecp::52616e646f6d495633363368676674792dd36b78f1d98017',
        'address_line_2'        => '♀ﬁ�⑀₂ἠḂӥẄɐː⍎אԱა Καλημέρα κόσμε, コンニチハ',
        'restricted_ip_address' => '',
        'salutation'            => 'Mr',
        'gender'                => 'm',
        'phone'                 => '21345678',
        'residence'             => 'af',
        'comment'               => '',
        'citizen'               => 'br'
    };

    my $client2 = BOM::User::Client->rnew(%$client_details);

    is($client2->loginid,    $client_details->{'loginid'},         'compare loginid between client object instantize with client hash ref');
    is($client2->broker,     $client_details->{'broker_code'},     'compare broker between client object instantize with client hash ref');
    is($client2->password,   $client_details->{'client_password'}, 'compare password between client object instantize with client hash ref');
    is($client2->email,      $client_details->{'email'},           'compare email between client object instantize with client hash ref');
    is($client2->last_name,  $client_details->{'last_name'},       'compare last_name between client object instantize with client hash ref');
    is($client2->first_name, $client_details->{'first_name'},      'compare first_name between client object instantize with client hash ref');

    is(length($client2->address_1), 50, "treats Unicode chars correctly");
    is(length($client2->address_2), 37, "treats Unicode chars correctly");

    is($client2->date_of_birth, $client_details->{'date_of_birth'}, 'compare date_of_birth between client object instantize with client hash ref');
    is(
        $client2->secret_question,
        $client_details->{'secret_question'},
        'compare secret_question between client object instantize with client hash ref'
    );
    is($client2->date_joined =~ /^$client_details->{'date_joined'}/, 1, 'compare date_joined between client object instantize with client hash ref');
    is($client2->email, $client_details->{'email'},                     'compare email between client object instantize with client hash ref');
    is(
        $client2->latest_environment,
        $client_details->{'latest_environment'},
        'compare latest_environment between client object instantize with client hash ref'
    );
    is($client2->secret_answer, $client_details->{'secret_answer'}, 'compare secret_answer between client object instantize with client hash ref');
    is(
        $client2->restricted_ip_address,
        $client_details->{'restricted_ip_address'},
        'compare restricted_ip_address between client object instantize with client hash ref'
    );
    is($client2->loginid,    $client_details->{'loginid'},    'compare loginid between client object instantize with client hash ref');
    is($client2->salutation, $client_details->{'salutation'}, 'compare salutation between client object instantize with client hash ref');
    is($client2->last_name,  $client_details->{'last_name'},  'compare last_name between client object instantize with client hash ref');
    is($client2->phone,      $client_details->{'phone'},      'compare phone between client object instantize with client hash ref');
    is($client2->residence,  $client_details->{'residence'},  'compare residence between client object instantize with client hash ref');
    is($client2->first_name, $client_details->{'first_name'}, 'compare first_name between client object instantize with client hash ref');
    is($client2->citizen,    $client_details->{'citizen'},    'compare citizen between client object instantize with client hash ref');

    $client_details = {
        'loginid'         => 'MX5090',
        'email'           => 'Calum@regentmarkets.com',
        'client_password' => '960f984285701c6d8dba5dc71c35c55c0397ff276b06423146dde88741ddf1af',
        'broker_code'     => 'MX',
        'allow_login'     => 1,
        'last_name'       => 'test initialize client obj by hash ref',
        'first_name'      => 'MX client',
        'residence'       => 'de',
    };

    $client2 = BOM::User::Client->rnew(%$client_details);

    is($client2->loginid,    $client_details->{'loginid'},         'compare loginid between client object instantize with another client hash ref');
    is($client2->broker,     $client_details->{'broker_code'},     'compare broker between client object instantize with another client hash ref');
    is($client2->password,   $client_details->{'client_password'}, 'compare password between client object instantize with another client hash ref');
    is($client2->email,      $client_details->{'email'},           'compare email between client object instantize with client another hash ref');
    is($client2->last_name,  $client_details->{'last_name'},       'compare last_name between client object instantize with another client hash ref');
    is($client2->first_name, $client_details->{'first_name'}, 'compare first_name between client object instantize with another client hash ref');
};

subtest 'validate_dob' => sub {
    my $age          = 23;
    my $mock_request = Test::MockModule->new('Brands::Countries');
    $mock_request->mock('minimum_age_for_country', sub { return $age });
    my $dob_result;

    my $minimum_date   = Date::Utility->new->_minus_years($age);
    my $specific_date  = Date::Utility->new('2016-02-29');
    my %data_dob_valid = (
        $minimum_date->date_yyyymmdd                                   => undef,
        $specific_date->minus_time_interval($age . 'y')->date_yyyymmdd => undef,
        $minimum_date->minus_time_interval(1 . 'y')->date_yyyymmdd     => undef,
        $minimum_date->minus_time_interval(30 . 'd')->date_yyyymmdd    => undef,
        $minimum_date->minus_time_interval(1 . 'd')->date_yyyymmdd     => undef
    );
    my %data_dob_invalid = (
        "13-03-21"                                                 => {error => 'InvalidDateOfBirth'},
        "1913-03-00"                                               => {error => 'InvalidDateOfBirth'},
        "1993-13-11"                                               => {error => 'InvalidDateOfBirth'},
        "1923-04-32"                                               => {error => 'InvalidDateOfBirth'},
        $minimum_date->plus_time_interval(1 . 'y')->date_yyyymmdd  => {error => 'BelowMinimumAge'},
        $minimum_date->plus_time_interval(30 . 'd')->date_yyyymmdd => {error => 'BelowMinimumAge'},
        $minimum_date->plus_time_interval(1 . 'd')->date_yyyymmdd  => {error => 'BelowMinimumAge'});

    foreach my $key (keys %data_dob_valid) {
        $dob_result = $client->validate_common_account_details({date_of_birth => $key});
        my $value = $data_dob_valid{$key};
        is($dob_result, $value, "Successfully validate_dob $key");
    }
    foreach my $key (keys %data_dob_invalid) {
        my $dob_result_hash = $client->validate_common_account_details({date_of_birth => $key});
        my $value_hash      = $data_dob_invalid{$key};
        is($dob_result_hash->{error}, $value_hash->{error}, "validate_dob gets error $key");
    }
};

subtest "format and validate" => sub {
    my $args = {first_name => ' newname '};
    $client->format_input_details($args);
    is $args->{first_name}, 'newname', 'trim firstname';

    $args = {phone => ''};
    is $client->format_input_details($args), undef, 'Empty phone number returns undef';

    $args = {phone => undef};
    is $client->format_input_details($args), undef, 'Undef phone number returns undef';

    delete $args->{phone};
    is $client->format_input_details($args), undef, 'Undef phone number returns undef';

    $args = {phone => 123456789};
    is $client->format_input_details($args), undef, 'we are not strict on phone number anymore';

    $args = {phone => '+442087712924'};
    is $client->format_input_details($args), undef, 'Valid UK phone number returns undef';

    $args = {phone => '123456a'};
    is $client->format_input_details($args)->{error}, 'InvalidPhone', 'Phone number should not contain alphabet characters';

    $args = {phone => '12345678'};
    is $client->format_input_details($args)->{error}, 'InvalidPhone', 'Phone number minimum lenght is 9';

    $args = {phone => '111111111'};
    is $client->format_input_details($args)->{error}, 'InvalidPhone', 'Repeated digits are disallowed';

    $args = {phone => '111131111'};
    is $client->format_input_details($args), undef, 'Not repeated digits are ok';

    $args = {phone => '111131113'};
    is $client->format_input_details($args), undef, 'Not repeated digits are ok';

    $args = {phone => '3111111111111'};
    is $client->format_input_details($args), undef, 'Not repeated digits are ok';

    $args = {phone => '+26777951234'};
    is $client->format_input_details($args), undef, 'Valid Botswana phone number returns undef';

    $args = {phone => '+(267)-77-951234'};
    is $client->format_input_details($args), undef, 'Valid Botswana phone number with special characters allowed';

    $args = {phone => '+(267) 77 951234'};
    is $client->format_input_details($args), undef, 'Valid Botswana phone number with special characters allowed';

    $args = {phone => '-26777951234'};
    is $client->format_input_details($args), undef, 'Valid Botswana phone number, can start with hyphen';

    $args = {phone => '+-26777951234'};
    is $client->format_input_details($args), undef, 'Valid Botswana phone number, hyphen can follow plus';

    $args = {date_of_birth => '2010-15-15'};
    is $client->format_input_details($args)->{error}, 'InvalidDateOfBirth', 'InvalidDateOfBirth';

    $args = {address_state => 'Dummy Value'};
    is $client->format_input_details($args), undef, 'No error for invalid state without residence';
    is $args->{address_state},               undef, 'Invalid state is removed if residence is empty';

    $args = {
        address_state => 'Dummy Value',
        residence     => 'id'
    };
    is $client->format_input_details($args)->{error}, 'InvalidState', 'Correct error for invalid state';

    $args = {
        address_state => 'Sumatera',
        residence     => 'id'
    };
    is $client->format_input_details($args), undef, 'No error for a valid state name with residence';
    is $args->{address_state},               'SM',  'State name is converted form text to code';

    $args = {date_of_birth => '2010-10-15'};
    is $client->validate_common_account_details($args)->{error}, 'BelowMinimumAge', 'validate_common_account_details: BelowMinimumAge';
    $args = {secret_question => 'test'};
    is $client->validate_common_account_details($args)->{error}, 'NeedBothSecret', 'validate_common_account_details: NeedBothSecret';

    $args = {place_of_birth => 'oo'};
    is $client->validate_common_account_details($args)->{error}, 'InvalidPlaceOfBirth', 'validate_common_account_details: InvalidPlaceOfBirth';

    $args = {citizen => 'oo'};
    is $client->validate_common_account_details($args)->{error}, 'InvalidCitizenship', 'validate_common_account_details: InvalidCitizenship';

    $args = {
        promo_code_status => 'claimed',
        promo_code        => ''
    };
    is $client->validate_common_account_details($args)->{error}, 'No promotion code was provided', 'correct error when no promotion code is provided';
    $args = {
        promo_code_status => 'claimed',
        promo_code        => 'BOM123'
    };
    is $client->validate_common_account_details($args), undef, 'validation is passed when both promotion code and status is provided';

    $args = {
        non_pep_declaration_time => 'abc',
    };
    is $client->validate_common_account_details($args)->{error}, 'InvalidNonPepTime', 'Invalid non-pep declaration time format error';

    $args = {
        non_pep_declaration_time => '2002-01-66',
    };
    is $client->validate_common_account_details($args)->{error}, 'InvalidNonPepTime', 'Invalid non-pep declaration time format error';

    $args = {
        non_pep_declaration_time => time + 1,
    };
    is $client->validate_common_account_details($args)->{error}, 'TooLateNonPepTime', 'Too late non-pep declaration time error';

    $args = {
        non_pep_declaration_time => undef,
    };
    is $client->validate_common_account_details($args), undef, 'Validation is passed with empty non-pep declaration time';

    $args = {
        non_pep_declaration_time => time,
    };
    is $client->validate_common_account_details($args), undef, 'Validation is passed with non-pep declaration time set to now';

    $args = {
        non_pep_declaration_time => Date::Utility->today->_plus_years(-1)->date_yyyymmdd,
    };
    is $client->validate_common_account_details($args), undef, 'Validation is passed with non-pep declaration time set to an earlier time';

    subtest 'P.O. Box' => sub {
        subtest 'Regulated accounts' => sub {
            my $client_details = {
                'loginid'         => 'MX5090',
                'email'           => 'Calum@regentmarkets.com',
                'client_password' => '960f984285701c6d8dba5dc71c35c55c0397ff276b06423146dde88741ddf1af',
                'broker_code'     => 'MX',
                'allow_login'     => 1,
                'last_name'       => 'test initialize client obj by hash ref',
                'first_name'      => 'MX client',
                'residence'       => 'de',
            };

            my $client = BOM::User::Client->rnew(%$client_details);
            $client_details->{address_line_1} = 'p o box 1234';
            my $result = $client->validate_common_account_details($client_details);
            is $result->{error}, 'PoBoxInAddress', 'Invalid PO BOX at address line 1';

            $client_details->{address_line_1} = 'somewhere';
            $client_details->{address_line_2} = 'P.O. box 2357111317';
            $result                           = $client->validate_common_account_details($client_details);
            is $result->{error}, 'PoBoxInAddress', 'Invalid PO BOX at address line 2';
        };

        subtest 'Unregulated accounts' => sub {
            my $client_details = {
                'loginid'         => 'CR110101',
                'email'           => 'test@email.com',
                'client_password' => '960f984285701c6d8dba5dc71c35c55c0397ff276b06423146dde88741ddf1af',
                'broker_code'     => 'CR',
                'allow_login'     => 1,
                'last_name'       => 'TEST',
                'first_name'      => 'CR client',
                'residence'       => 'br',
            };

            my $client = BOM::User::Client->rnew(%$client_details);
            $client_details->{address_line_1} = 'p o box 1234';
            my $result = $client->validate_common_account_details($client_details);
            is $result->{error}, undef, 'PO BOX not checked at address line 1';

            $client_details->{address_line_1} = 'somewhere';
            $client_details->{address_line_2} = 'P.O. box 2357111317';
            $result                           = $client->validate_common_account_details($client_details);
            is $result->{error}, undef, 'PO BOX not checked at address line 2';
        };
    };
};

subtest "check duplicate accounts" => sub {
    plan tests => 10;

    my $client_details = {
        first_name    => 'alan',
        last_name     => 'turing',
        date_of_birth => '1983-01-01',
    };

    my $first_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'cr_dupe1@test.com',
        residence   => 'id',
        %$client_details,
    });

    my $second_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'cr_dupe2@test.com',
        residence   => 'in',
    });

    is $second_client->check_duplicate_account($client_details)->{error}, 'DuplicateAccount',
        'second client is considered as duplicate same name + dob with different email account';

    $first_client->status->set('disabled', 'system', 'test');

    is $second_client->check_duplicate_account($client_details)->{error}, 'DuplicateAccount',
        'second client is considered as duplicate regardless if first client is disabled';

    $second_client->email($first_client->email);
    is $second_client->check_duplicate_account($client_details), undef,
        'no duplicate as emails are same, could have different currency in the account';

    my $third_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'cr_dupe3@test.com',
        residence   => 'au',
    });

    $third_client->first_name('Ada');
    $third_client->last_name('Lovelace');
    $third_client->date_of_birth('1815-12-10');
    $third_client->phone('+4411223344');
    $third_client->save;
    my $same_details = {
        first_name    => 'Ada',
        last_name     => 'Lovelace',
        date_of_birth => '1815-12-10',
        phone         => '+4411223344',
    };
    my $result = $third_client->check_duplicate_account($same_details);
    is $result, undef, "No duplicate, the modified details are the same as the details present in the current client";

    delete $same_details->{first_name};
    delete $same_details->{last_name};

    $result = $third_client->check_duplicate_account($same_details);
    is $result, undef,
        "No duplicate, the modified details are the same as the details present in the current client, even if name or last name ar not present in the details to change";

    delete $same_details->{date_of_birth};
    $result = $third_client->check_duplicate_account($same_details);
    is $result, undef, "No duplicate, the modified details are the same as the details present in the current client, even if only phone is provided";

    my $modified_details = {
        first_name    => $second_client->first_name,
        last_name     => $second_client->last_name,
        date_of_birth => $second_client->date_of_birth,
        phone         => $second_client->phone,
    };
    $result = $third_client->check_duplicate_account($modified_details);
    ok $result, 'A result is returned from check_duplicate_account';
    is $result->{error}, 'DuplicateAccount', 'duplicated account found, same data than a different client account (different emails)';

    delete $modified_details->{first_name};
    delete $modified_details->{last_name};
    delete $modified_details->{date_of_birth};
    $result = $third_client->check_duplicate_account($modified_details);
    is $result, undef, 'No duplicated account found, same phone number alone doesn\'t consider duplicate account';

    my $client_mf1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        email         => 'mf1@test.com',
        residence     => 'at',
        broker_code   => 'MF',
        first_name    => 'robert',
        last_name     => 'smith',
        date_of_birth => '2000-01-01',
    });

    my $client_mf2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        email         => 'mf2@test.com',
        residence     => 'at',
        broker_code   => 'MF',
        first_name    => 'bob',
        last_name     => 'smith',
        date_of_birth => '2000-01-01',
    });

    $result = $client_mf1->check_duplicate_account({first_name => 'bob'});
    cmp_deeply(
        $result,
        {
            error   => 'DuplicateAccount',
            details => bag(
                $client_mf2->loginid,     $client_mf2->first_name, $client_mf2->last_name, $client_mf2->date_of_birth,
                $client_mf2->date_joined, $client_mf2->email,      $client_mf2->phone,
            ),
        },
        'duplicate in upgradeable landing company'
    );
};

subtest "immutable_fields and validate_immutable_fields" => sub {
    my $email     = 'immutable@test.com';
    my $client_vr = create_client('VRTC');
    $client_vr->email($email);
    $client_vr->save;

    my $client_cr = create_client('CR');
    $client_cr->email($email);
    $client_cr->tax_identification_number('123456789');
    $client_cr->place_of_birth('fr');
    $client_cr->tax_residence('br');
    $client_cr->account_opening_reason('Speculative');
    $client_cr->save;

    my $client_mlt = create_client('MLT');
    $client_mlt->email($email);
    $client_mlt->tax_identification_number('123456789');
    $client_mlt->place_of_birth('fr');
    $client_mlt->tax_residence('br');
    $client_mlt->account_opening_reason('Speculative');
    $client_mlt->save;

    my $test_user = BOM::User->create(
        email          => $email,
        password       => "hello",
        email_verified => 1,
    );

    $test_user->add_client($client_vr);
    $test_user->add_client($client_cr);
    $test_user->add_client($client_mlt);

    my $changeable_fields;
    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->mock(
        changeable_fields => sub {
            my $lc = shift;
            # different settings for different landing companies
            return $changeable_fields->{$lc->short};
        });

    my @all_immutables = BOM::User::Client::PROFILE_FIELDS_IMMUTABLE_AFTER_AUTH->@*;

    subtest 'empty values' => sub {
        test_immutable_fields(\@all_immutables, $test_user, 'default list of immutable fields is correct');

        my @empty_fields;
        for my $field (
            qw/account_opening_reason citizen place_of_birth
            salutation secret_answer secret_question tax_residence tax_identification_number/
            )
        {

            my $original_value = $client_cr->$field;

            $client_cr->$field('');
            $client_mlt->$field('');
            $client_cr->save;
            $client_mlt->save;

            my @empty_fields = ($field);
            test_immutable_fields([array_minus @all_immutables, @empty_fields], $test_user, "empty field $field is removed from immutables");

            # restore the original value
            $client_cr->$field($original_value);
            $client_mlt->$field($original_value);
            $client_cr->save;
            $client_mlt->save;
        }
    };

    my $test_status = {
        svg   => 'none',
        malta => 'none'
    };

    my $mock_status = Test::MockModule->new('BOM::User::Client::Status');
    $mock_status->mock(
        age_verification => sub {
            my ($self) = @_;

            my $client   = BOM::User::Client->new({loginid => $self->client_loginid});
            my $lc_short = $client->landing_company->short;

            my $status = $test_status->{$lc_short} // '';

            return {
                staff_name => 'system',
                reason     => 'test',
            } if $status eq 'verified';

            return undef;
        });

    subtest 'poi and authentication' => sub {
        my @excluded_fields;
        my @poi_name_mismatch_fields = qw(first_name last_name);
        my @poi_dob_mismatch_fields  = qw(date_of_birth);

        $client_mlt->status->clear_age_verification;
        $client_mlt->status->_clear_all;

        for my $field (@all_immutables) {
            push @excluded_fields, $field;

            $changeable_fields->{svg}->{only_before_auth}   = [];
            $changeable_fields->{malta}->{only_before_auth} = [];
            test_immutable_fields([@all_immutables], $test_user, "list of immutable fields is not changed without only_before_auth");

            $changeable_fields->{svg}->{only_before_auth}   = [$field];
            $changeable_fields->{malta}->{only_before_auth} = [];

            my @excluded_field = ($field);
            test_immutable_fields([array_minus(@all_immutables, @excluded_field)],
                $test_user, "$field is removed from immutable fields of both clients by setting just for one landing company");

            $changeable_fields->{svg}->{only_before_auth}   = [];
            $changeable_fields->{malta}->{only_before_auth} = [@excluded_fields];
            test_immutable_fields([array_minus(@all_immutables, @excluded_fields)],
                $test_user, "many fields are removed from immutable fields of both clients by setting just for one landing company");
        }

        test_immutable_fields([], $test_user, "all fields are changeable now");

        $test_status->{svg} = 'verified';
        cmp_bag [$client_cr->immutable_fields], \@all_immutables, "Immutable fields are reverted to default after authentication";

        $test_status->{svg} = 'pending';
        $client_cr->status->setnx('poi_name_mismatch', 'test', 'test');

        my $immutable_fields_hash = +{map { ($_ => 1) } $client_cr->immutable_fields};

        cmp_bag [uniq($client_cr->immutable_fields)], [], "Empty immutable fields (without being age verified)";

        ok !$immutable_fields_hash->{first_name}, 'can edit first name';
        ok !$immutable_fields_hash->{last_name},  'can edit last name';

        $client_cr->status->clear_poi_name_mismatch;

        $client_cr->status->setnx('poi_dob_mismatch', 'test', 'test');
        $immutable_fields_hash = +{map { ($_ => 1) } $client_cr->immutable_fields};

        cmp_bag [uniq($client_cr->immutable_fields)], [], "Empty immutable fields (without being age verified)";

        ok !$immutable_fields_hash->{date_of_birth}, 'can edit dob';

        $client_cr->status->clear_poi_dob_mismatch;

        $client_cr->status->setnx('poi_name_mismatch', 'test', 'test');
        $test_status->{svg} = 'verified';

        cmp_bag [$client_cr->immutable_fields], \@all_immutables,
            "Cannot update first_name and last_name on name mismatch case if already age verified";
        $client_cr->status->clear_poi_name_mismatch;
        $client_cr->status->_clear_all;

        # basically, the lock has more weight
        subtest 'personal_detail_locked and poi_name_mismatch' => sub {
            $client_cr->status->setnx('personal_details_locked', 'test', 'test');
            cmp_bag [uniq($client_cr->immutable_fields)], \@all_immutables, "Personal details locked has more weight";
        };

        $client_cr->status->clear_personal_details_locked;
        $client_cr->status->clear_poi_name_mismatch;
        $client_cr->status->clear_age_verification;
        $test_status->{svg} = 'none';
        cmp_bag [$client_cr->immutable_fields], [], "Immutable fields are reverted to empty";
    };

    subtest 'Age verified/fully authenticated/address verified with poi/poa expired scenario' => sub {
        my @identity_fields = ('first_name',   'last_name', 'date_of_birth');
        my @address_fields  = ('address_city', 'address_line_1', 'address_line_2', 'address_postcode', 'address_state');

        my $mock_client = Test::MockModule->new('BOM::User::Client');
        my $poi_status;
        $mock_client->mock(
            get_poi_status => sub {
                return $poi_status // 'none';
            });
        my $poa_status;
        $mock_client->mock(
            get_poa_status => sub {
                return $poa_status // 'none';
            });
        my $fully_authenticated;
        $mock_client->mock(
            fully_authenticated => sub {
                return $fully_authenticated // 0;
            });

        test_immutable_fields([], $test_user, "Immutable fields are empty");

        $test_status->{svg} = 'verified';
        my $immutable_fields_hash = +{map { ($_ => 1) } $client_cr->immutable_fields};
        for my $identity_field (@identity_fields) {
            ok $immutable_fields_hash->{$identity_field}, "Age verified cannot update $identity_field identity field";
        }

        $poi_status            = 'expired';
        $immutable_fields_hash = +{map { ($_ => 1) } $client_cr->immutable_fields};
        for my $identity_field (@identity_fields) {
            ok $immutable_fields_hash->{$identity_field}, "Age verified and poi expired cannot update $identity_field identity field";
        }

        $poi_status = 'none';
        $test_status->{svg} = 'none';
        $client_cr->status->clear_age_verification;
        cmp_bag [$client_cr->immutable_fields], [], "Immutable fields reverted to empty";

        $fully_authenticated   = 1;
        $immutable_fields_hash = +{map { ($_ => 1) } $client_cr->immutable_fields};
        for my $address_field (@address_fields) {
            ok $immutable_fields_hash->{$address_field}, "Fully authenticated cannot update $address_field address field";
        }

        $poa_status            = 'expired';
        $immutable_fields_hash = +{map { ($_ => 1) } $client_cr->immutable_fields};
        for my $address_field (@address_fields) {
            ok !$immutable_fields_hash->{$address_field}, "Fully authenticated and poa expired can update $address_field address field";
        }

        $poa_status          = 'none';
        $fully_authenticated = 0;
        $test_status->{svg}  = 'none';
        cmp_bag [$client_cr->immutable_fields], [], "Immutable fields reverted to empty";

        $client_cr->status->upsert('address_verified', 'system', 'address verified');
        $immutable_fields_hash = +{map { ($_ => 1) } $client_cr->immutable_fields};
        for my $address_field (@address_fields) {
            ok $immutable_fields_hash->{$address_field}, "Address verified cannot update $address_field address field";
        }

        $poa_status            = 'expired';
        $immutable_fields_hash = +{map { ($_ => 1) } $client_cr->immutable_fields};
        for my $address_field (@address_fields) {
            ok !$immutable_fields_hash->{$address_field}, "Address verified and poa expired can update $address_field address field";
        }

        $mock_client->unmock_all;
        $test_status->{svg} = 'none';
        $client_cr->status->clear_address_verified;
        cmp_bag [$client_cr->immutable_fields], [], "Immutable fields reverted to empty";
    };

    subtest 'personal_details_locked status' => sub {
        test_immutable_fields([], $test_user, 'the field is not immutable before authentication');

        $client_cr->status->set('personal_details_locked', 'system', 'just testing');
        $client_cr->status->_clear_all;

        $changeable_fields->{svg}->{only_before_auth}   = [];
        $changeable_fields->{malta}->{only_before_auth} = [
            'account_opening_reason', 'citizen',         'date_of_birth',             'first_name',
            'last_name',              'place_of_birth',  'residence',                 'salutation',
            'secret_answer',          'secret_question', 'tax_identification_number', 'tax_residence'
        ];

        $changeable_fields->{svg}->{personal_details_not_locked}   = [];
        $changeable_fields->{malta}->{personal_details_not_locked} = [];
        test_immutable_fields([], $test_user, 'the field is not immutable before it is included in landing company config');

        $changeable_fields->{svg}->{personal_details_not_locked} = ['first_name'];
        test_immutable_fields([qw/first_name/], $test_user, 'the field is immutable after adding it to LC conf');

        $changeable_fields->{svg}->{personal_details_not_locked} = ['first_name', 'last_name', 'date_of_birth', 'made_up'];
        test_immutable_fields([qw/first_name last_name date_of_birth made_up/], $test_user, 'many fields are immutable after adding them to LC conf');

        $changeable_fields->{malta}->{personal_details_not_locked} = ['first_name', 'last_name', 'date_of_birth', 'imaginary'];
        test_immutable_fields([qw/first_name last_name date_of_birth made_up/], $test_user, 'many fields are immutable after adding them to LC');

        $client_mlt->status->set('personal_details_locked', 'system', 'just testing mlt');
        $client_mlt->status->_clear_all;

        $changeable_fields->{malta}->{personal_details_not_locked} = ['first_name', 'last_name', 'date_of_birth', 'imaginary'];
        test_immutable_fields([qw/first_name last_name date_of_birth made_up imaginary/],
            $test_user, 'many fields are immutable after adding them to LC, and can be seen across LCs if the status is present');

        # kicks in evern if authenticated
        $client_cr->status->set('age_verification', 'system', 'just testing');
        $client_cr->status->_clear_all;

        $changeable_fields->{malta}->{personal_details_not_locked} = ['first_name', 'last_name', 'date_of_birth', 'imaginary'];
        test_immutable_fields([qw/first_name last_name date_of_birth made_up imaginary/],
            $test_user,
            'many fields are immutable after adding them to LC, and can be seen across LCs if the status is present even if authenticated');
    };

    subtest 'address_locked status' => sub {
        $client_cr->status->set('address_verified', 'system', 'just testing');

        cmp_deeply ['address_city', 'address_line_1', 'address_line_2', 'address_postcode', 'address_state'], subsetof($client_cr->immutable_fields),
            'address fields are immutable - address verified ';

        $client_cr->status->clear_address_verified;
        $client_cr->status->_clear_all;

        cmp_deeply ['address_city', 'address_line_1', 'address_line_2', 'address_postcode', 'address_state'], none($client_cr->immutable_fields),
            'address fields are mutable again';

        $client_cr->set_authentication('ID_DOCUMENT', {status => 'pass'});

        cmp_deeply ['address_city', 'address_line_1', 'address_line_2', 'address_postcode', 'address_state'], subsetof($client_cr->immutable_fields),
            'address fields are immutable - fully authenticated ';

    };

    $mock_status->unmock_all;
    $mock_lc->unmock_all;
};

subtest 'returns correct required_fields for each landing company' => sub {
    my $email = 'required_fields_test@test.com';

    my $client_cr = create_client('CR');
    $client_cr->email($email);
    $client_cr->save;

    my $client_mlt = create_client('MLT');
    $client_mlt->email($email);
    $client_mlt->save;

    my $client_mf = create_client('MF');
    $client_mf->email($email);
    $client_mf->save;

    my $client_iom = create_client('MX');
    $client_iom->email($email);
    $client_iom->save;

    my $user = BOM::User->create(
        email          => $email,
        password       => "hello",
        email_verified => 1,
    );

    $user->add_client($client_cr);
    $user->add_client($client_mlt);
    $user->add_client($client_mf);
    $user->add_client($client_iom);

    subtest 'svg' => sub {
        my @list            = qw(first_name last_name residence date_of_birth address_city address_line_1);
        my @required_fields = $client_cr->required_fields;
        cmp_bag \@required_fields, \@list, "List of required fields for svg is OK";
        test_validation_on_required_fields(\@list, $client_cr);
    };

    subtest 'malta' => sub {
        my @list            = qw(salutation citizen first_name last_name date_of_birth residence address_line_1 address_city);
        my @required_fields = $client_mlt->required_fields;
        cmp_bag \@required_fields, \@list, "List of required fields for malta is OK";
        test_validation_on_required_fields(\@list, $client_mlt);
    };

    subtest 'maltainvest' => sub {
        my @list =
            qw(salutation citizen tax_residence tax_identification_number first_name last_name date_of_birth residence address_line_1 address_city account_opening_reason expiration_check fully_authenticated);
        my @required_fields = $client_mf->required_fields;
        cmp_bag \@required_fields, \@list, "List of required fields for maltainvest is OK";
        test_validation_on_required_fields(\@list, $client_mf);
    };

    subtest 'iom' => sub {
        my @list            = qw(salutation citizen first_name last_name date_of_birth residence address_line_1 address_city address_postcode);
        my @required_fields = $client_iom->required_fields;
        cmp_bag \@required_fields, \@list, "List of required fields for iom is OK";
        test_validation_on_required_fields(\@list, $client_iom);
    };
};

subtest 'benched client' => sub {
    my $email     = 'benched@test.com';
    my $client_cr = create_client('CR');
    $client_cr->email($email);
    $client_cr->save;

    my $client_cr2 = create_client('CR');
    $client_cr2->email($email);
    $client_cr2->save;

    my $client_mf = create_client('MF');
    $client_mf->email($email);
    $client_mf->save;

    my $user = BOM::User->create(
        email          => $email,
        password       => "hey you",
        email_verified => 1,
    );

    $user->add_client($client_mf);
    $user->add_client($client_cr);

    $client_cr->binary_user_id($user->id);
    $client_cr->user($user);
    $client_cr->save;

    $client_mf->binary_user_id($user->id);
    $client_mf->user($user);
    $client_mf->save;

    ok !$client_mf->benched, 'non duplicated account cannot be benched';
    ok !$client_cr->benched, 'non duplicated account cannot be benched';

    $client_cr->status->set('duplicate_account', 'test', 'test');

    ok !$client_cr->benched, 'non duplicated not yet benched';

    my $cli_mock = Test::MockModule->new(ref($client_cr));

    my $date_joined_config = {};

    $cli_mock->mock(
        'date_joined',
        sub {
            my $cli = shift;

            return $date_joined_config->{$cli->loginid};
        });

    $user->add_client($client_cr2);
    $client_cr2->binary_user_id($user->id);
    $client_cr2->user($user);
    $client_cr2->save;
    $client_cr = BOM::User::Client->new({loginid => $client_cr->loginid});    # reload client to avoid cache hits

    ok !$client_cr->benched, 'CR not benched (cannot tell without date joined)';

    $date_joined_config->{$client_cr2->loginid} = '2020-10-10 10:10:10';

    ok !$client_cr->benched, 'CR not benched (cannot tell without date joined)';

    $date_joined_config->{$client_cr->loginid} = '2020-10-10 10:10:10';

    ok !$client_cr->benched, 'CR not benched (same stamp)';

    $date_joined_config->{$client_cr->loginid} = '2020-10-10 10:10:09';

    ok $client_cr->benched,  'CR got benched';
    ok !$client_mf->benched, 'MF not benched (unaffected by CR)';

    $date_joined_config->{$client_cr->loginid} = '2020-10-10 10:10:11';
    $date_joined_config->{$client_mf->loginid} = '2020-10-10 10:10:09';

    ok !$client_cr->benched, 'CR not benched (created after)';
    ok !$client_mf->benched, 'MF not benched (unaffected by CR)';

    my $broker_code_config = {};

    $cli_mock->mock(
        'broker_code',
        sub {
            my ($cli) = @_;

            return $broker_code_config->{$cli->loginid} // $cli_mock->original('broker_code')->(@_);
        });

    $broker_code_config->{$client_cr->loginid} = 'MF';

    ok !$client_mf->benched, 'MF not benched (not dup)';

    $client_mf->status->set('duplicate_account', 'test', 'test');

    $client_cr->status->clear_duplicate_account;
    $client_cr->status->_clear_all;

    ok $client_mf->benched, 'MF got benched (by CR)';

    $client_cr->status->set('duplicate_account', 'test', 'test');
    $client_cr->status->_clear_all;

    ok $client_mf->benched, 'MF got benched (can be benched by a dup)';

    $date_joined_config->{$client_cr->loginid} = '2020-10-10 10:10:09';

    ok !$client_mf->benched, 'MF not benched';
    ok !$client_cr->benched, 'CR not benched (equal to MF)';

    $date_joined_config->{$client_cr->loginid} = '2020-10-10 10:10:08';

    ok !$client_mf->benched, 'MF not benched';
    ok $client_cr->benched,  'CR got benched (by MF)';

    # playing with currency type
    $client_cr->set_default_account('BTC');
    is $client_cr->currency, 'BTC', 'changed currency to BTC';

    ok !$client_mf->benched, 'MF not benched';
    ok !$client_cr->benched, 'CR not benched (currency type changed)';

    $client_mf->set_default_account('BTC');
    is $client_mf->currency, 'BTC', 'changed currency to BTC';

    ok !$client_mf->benched, 'MF not benched';
    ok $client_cr->benched,  'CR got benched (same currency type)';

    $date_joined_config->{$client_cr->loginid} = '2020-10-10 10:10:11';

    ok $client_mf->benched,  'MF got benched';
    ok !$client_cr->benched, 'CR not benched';

    $cli_mock->unmock_all;
};

subtest 'immutable fields for a real account having duplicate accounts' => sub {
    my $email  = 'immutable_real_x_real@test.com';
    my $email2 = 'immutable_real_x_real2@test.com';

    my $client_cr = create_client('CR');
    $client_cr->email($email);
    $client_cr->save;

    my $client_cr2 = create_client('CR');
    $client_cr2->email($email);
    $client_cr2->save;

    my $client_mf = create_client('MF');
    $client_mf->email($email);
    $client_mf->save;

    my $client_mf2 = create_client('MF');
    $client_mf->email($email2);
    $client_mf->save;

    my $client_mf3 = create_client('MF');
    $client_mf->email($email);
    $client_mf->save;

    my $user = BOM::User->create(
        email          => $email,
        password       => "hey you",
        email_verified => 1,
    );

    my $user2 = BOM::User->create(
        email          => $email2,
        password       => "hey you",
        email_verified => 1,
    );

    $client_mf->status->clear_age_verification;
    $client_mf->status->_clear_all;
    $client_mf2->status->clear_age_verification;
    $client_mf2->status->_clear_all;
    $client_mf3->status->clear_age_verification;
    $client_mf3->status->_clear_all;

    $_->delete for @{$client_cr2->client_authentication_method};
    $_->delete for @{$client_cr->client_authentication_method};
    $_->delete for @{$client_mf->client_authentication_method};
    $_->delete for @{$client_mf2->client_authentication_method};
    $_->delete for @{$client_mf3->client_authentication_method};

    $client_cr  = BOM::User::Client->new({loginid => $client_cr->loginid});     # reload client to avoid cache issues
    $client_cr2 = BOM::User::Client->new({loginid => $client_cr2->loginid});    # reload client to avoid cache issues
    $client_mf  = BOM::User::Client->new({loginid => $client_mf->loginid});     # reload client to avoid cache issues
    $client_mf2 = BOM::User::Client->new({loginid => $client_mf2->loginid});    # reload client to avoid cache issues
    $client_mf3 = BOM::User::Client->new({loginid => $client_mf3->loginid});    # reload client to avoid cache issues

    cmp_bag $client_cr->status->all,  [], 'client CR has no status';
    cmp_bag $client_mf->status->all,  [], 'client MF has no status';
    cmp_bag $client_mf2->status->all, [], 'client MF2 has no status';
    ok !$client_cr->fully_authenticated,  'client CR not fully auth';
    ok !$client_mf->fully_authenticated,  'client MF not fully auth';
    ok !$client_mf2->fully_authenticated, 'client MF2 not fully auth';

    $user->add_client($client_cr);
    cmp_bag [$client_cr->immutable_fields], [qw/residence secret_answer secret_question/], 'Expected immutable fields CR alone';

    $user2->add_client($client_mf2);
    cmp_bag [$client_mf2->immutable_fields], [qw/residence secret_answer secret_question/], 'Expected immutable fields MF alone';

    # now make MF + CR siblings
    $user->add_client($client_mf);
    cmp_bag [$client_cr->immutable_fields], [qw/residence secret_answer secret_question/], 'Expected immutable fields CR + MF';
    cmp_bag [$client_mf->immutable_fields], [qw/residence secret_answer secret_question/], 'Expected immutable fields MF + CR';

    # make MF duplicated
    $client_mf->status->set('duplicate_account', 'test', 'Duplicate account - currency change');
    $client_mf->status->_clear_all;
    is $client_mf->status->reason('duplicate_account'), 'Duplicate account - currency change', 'duplicated MF with the right reason';

    my @dup_fields =
        qw/residence secret_answer secret_question citizen salutation first_name last_name date_of_birth address_city address_line_1 address_line_2 address_postcode address_state phone/;

    cmp_bag [$client_cr->immutable_fields], [@dup_fields], 'Expected immutable fields CR + MF (dup account is very immutable)';
    cmp_bag [$client_mf->immutable_fields], [@dup_fields], 'Expected immutable fields MF + CR (dup account is very immutable)';

    # give FA
    my @fa_fields = +BOM::User::Client::FA_FIELDS_IMMUTABLE_DUPLICATED->@*;
    my $fa        = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
    $client_mf->financial_assessment({
        data => encode_json_utf8($fa),
    });
    $client_mf->save();
    $client_mf = BOM::User::Client->new({loginid => $client_mf->loginid});    # reload client to avoid cache issues

    cmp_bag [$client_cr->immutable_fields], [@dup_fields, @fa_fields], 'Expected immutable fields CR + MF (FA fields on dup)';

    cmp_bag [$client_mf->immutable_fields], [@dup_fields, @fa_fields], 'Expected immutable fields MF + CR (FA fields on dup)';

    # remove dup
    $client_mf->status->clear_duplicate_account;
    $client_mf->status->_clear_all;
    ok !$client_mf->status->duplicate_account, 'MF is no longer a dup';

    cmp_bag [$client_cr->immutable_fields], [qw/residence secret_answer secret_question/], 'Expected immutable fields CR + MF (come back to normal)';

    cmp_bag [$client_mf->immutable_fields], [qw/residence secret_answer secret_question/], 'Expected immutable fields MF + CR (come back to normal)';

    # give dup to CR
    $client_cr->status->set('duplicate_account', 'test', 'Duplicate account - currency change');
    $client_cr->status->_clear_all;
    is $client_cr->status->reason('duplicate_account'), 'Duplicate account - currency change', 'duplicated MF with the right reason';

    cmp_bag [$client_cr->immutable_fields], [@dup_fields], 'Expected immutable fields CR + MF (dup CR)';

    cmp_bag [$client_mf->immutable_fields], [@dup_fields], 'Expected immutable fields MF + CR (dup CR)';

    # bench CR
    my $cli_mock           = Test::MockModule->new(ref($client_cr));
    my $date_joined_config = {};

    $cli_mock->mock(
        'date_joined',
        sub {
            my ($cli) = @_;

            return $date_joined_config->{$cli->loginid} // $cli_mock->original('date_joined')->(@_);
        });

    $user->add_client($client_cr2);
    $date_joined_config->{$client_cr2->loginid} = Date::Utility->new()->plus_time_interval('10y')->datetime_yyyymmdd_hhmmss;

    cmp_bag [$client_cr->immutable_fields], [], 'Expected empty immutable fields for a benched client';

    cmp_bag [$client_cr2->immutable_fields], [qw/residence secret_answer secret_question/], 'Expected normalish immutable fields';

    cmp_bag [$client_mf->immutable_fields], [qw/residence secret_answer secret_question/], 'Expected normalish immutable fields';

    # make MF duplicated again
    $client_mf->status->set('duplicate_account', 'test', 'Duplicate account - currency change');
    $client_mf->status->_clear_all;
    is $client_mf->status->reason('duplicate_account'), 'Duplicate account - currency change', 'duplicated MF with the right reason';

    cmp_bag [$client_cr->immutable_fields], [], 'Empty fields for a benched client';

    cmp_bag [$client_cr2->immutable_fields], [@dup_fields, @fa_fields], 'Expected immutable fields CR + MF (FA fields on dup)';

    cmp_bag [$client_mf->immutable_fields], [@dup_fields, @fa_fields], 'Expected immutable fields MF + CR (FA fields on dup)';

    # bench the MF
    $user->add_client($client_mf3);
    $date_joined_config->{$client_mf3->loginid} = Date::Utility->new()->plus_time_interval('10y')->datetime_yyyymmdd_hhmmss;
    ok $client_mf->benched, 'mf is benched now';

    cmp_bag [$client_cr->immutable_fields], [], 'Empty fields for a benched client';

    cmp_bag [$client_cr2->immutable_fields], [qw/residence secret_answer secret_question/], 'Back to normalish immutable fields';

    cmp_bag [$client_mf->immutable_fields], [], 'Empty fields for a benched client';

    cmp_bag [$client_mf3->immutable_fields], [qw/residence secret_answer secret_question/], 'Back to normalish immutable fields';

    # make MF duplicated again
    $client_mf3->status->set('duplicate_account', 'test', 'Duplicate account - currency change');
    $client_mf3->status->_clear_all;
    is $client_mf3->status->reason('duplicate_account'), 'Duplicate account - currency change', 'duplicated MF with the right reason';
    ok $client_mf->benched, 'mf is benched now';

    cmp_bag [$client_cr->immutable_fields], [], 'Empty fields for a benched client';

    cmp_bag [$client_cr2->immutable_fields], [@dup_fields], 'Expected immutable fields CR + MF';

    cmp_bag [$client_mf->immutable_fields], [], 'Empty fields for a benched client';

    cmp_bag [$client_mf3->immutable_fields], [@dup_fields], 'Expected immutable fields MF + CR';

    # give FA
    # note in production this scenario might not happen as the new MF would have copied the FA from
    # the benched client at the get go, good to cover all scenarios nonetheless
    $client_mf3->financial_assessment({
        data => encode_json_utf8($fa),
    });
    $client_mf3->save();
    $client_mf3 = BOM::User::Client->new({loginid => $client_mf3->loginid});    # reload client to avoid cache issues

    cmp_bag [$client_cr->immutable_fields], [], 'Empty fields for a benched client';

    cmp_bag [$client_cr2->immutable_fields], [@dup_fields, @fa_fields], 'Expected immutable fields CR + MF (FA fields on dup)';

    cmp_bag [$client_mf->immutable_fields], [], 'Empty fields for a benched client';

    cmp_bag [$client_mf3->immutable_fields], [@dup_fields, @fa_fields], 'Expected immutable fields MF + CR (FA fields on dup)';

    $cli_mock->unmock_all;
};

sub test_immutable_fields {
    my ($fields, $user, $message) = @_;

    is scalar $user->clients, 3, 'Correct number of clients';
    for my $client ($user->clients) {
        my $expected_list = $client->is_virtual ? ['residence']                                               : $fields;
        my $msg           = $client->is_virtual ? 'Immutable fields are always the same for virtual accounts' : $message;

        my $landing_company = $client->landing_company->short;

        cmp_bag [$client->immutable_fields], $expected_list, "$msg - $landing_company";
    }
}

sub test_validation_on_required_fields {
    my ($list, $client) = @_;

    subtest 'Validation on empty values on required fields' => sub {
        for my $field (@$list) {
            my $args  = {$field => "  \r  \f\t\n \t\t\t\r"};
            my $error = $client->validate_common_account_details($args);
            is $error->{error},            'InputValidationFailed', 'error code is OK - InputValidationFailed';
            is $error->{details}->{field}, $field,                  "error details is OK - $field";
        }
    }
}

done_testing();
