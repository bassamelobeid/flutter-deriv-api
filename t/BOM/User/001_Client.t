use utf8;
binmode STDOUT, ':utf8';

use strict;
use warnings;

use Test::MockTime;
use Test::More qw( no_plan );
use Test::Deep;
use Test::Exception;
use Test::MockModule;

use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );

use Date::Utility;
use Array::Utils qw(array_minus);

my $login_id = 'CR0022';
my $client;

subtest "Client load and saving." => sub {
    plan tests => 43;
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
    is($client2->email, $client_details->{'email'}, 'compare email between client object instantize with client hash ref');
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
            is $result->{error}, 'invalid PO Box', 'Invalid PO BOX at address line 1';

            $client_details->{address_line_1} = 'somewhere';
            $client_details->{address_line_2} = 'P.O. box 2357111317';
            $result                           = $client->validate_common_account_details($client_details);
            is $result->{error}, 'invalid PO Box', 'Invalid PO BOX at address line 2';
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
    plan tests => 9;

    my $client_details = {
        first_name    => 'alan',
        last_name     => 'turing',
        date_of_birth => '1983-01-01'
    };

    my $first_client = BOM::User::Client->new({loginid => 'CR0001'});

    $first_client->last_name($client_details->{last_name});
    $first_client->first_name($client_details->{first_name});
    $first_client->date_of_birth($client_details->{date_of_birth});
    $first_client->email('another@email.com');
    $first_client->save;

    $first_client = BOM::User::Client->new({loginid => 'CR0001'});

    my $second_client = BOM::User::Client->new({loginid => 'CR0002'});

    is $second_client->check_duplicate_account($client_details)->{error}, 'DuplicateAccount',
        'second client is considered as duplicate same name + dob with different email account';

    $first_client->status->set('disabled', 'system', 'test');

    is $second_client->check_duplicate_account($client_details)->{error}, 'DuplicateAccount',
        'second client is considered as duplicate regardless if first client is disabled';

    $second_client->email($first_client->email);
    is $second_client->check_duplicate_account($client_details), undef,
        'no duplicate as emails are same, could have different currency in the account';

    my $third_client = BOM::User::Client->new({loginid => 'CR0003'});
    $third_client->email('ada@lovelace.com');
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
            qw/account_opening_reason citizen first_name last_name place_of_birth
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

    my $test_poi_status = {
        svg   => 'none',
        malta => 'none'
    };

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(get_poi_status => sub { return $test_poi_status->{shift->landing_company->short} });

    subtest 'poi and authentication' => sub {
        my @excluded_fields;
        for my $field (@all_immutables) {
            push @excluded_fields, $field;

            $changeable_fields->{svg}->{only_before_auth} = [@excluded_fields];
            test_immutable_fields([array_minus(@all_immutables, @excluded_fields), $field],
                $test_user, "list of immutable fields is not changed without only_before_auth");

            $changeable_fields->{malta}->{only_before_auth} = [@excluded_fields];
            test_immutable_fields([array_minus(@all_immutables, @excluded_fields)],
                $test_user, "$field is removed from immutable fields of both clients by setting just for one landing company");
        }

        test_immutable_fields([], $test_user, "all fields are changeable now");

        $test_poi_status->{svg} = 'verified';
        cmp_bag [$client_cr->immutable_fields], \@all_immutables, "Immutable fields are reverted to default after authentication";

        $test_poi_status->{svg} = 'expired';
        cmp_bag [$client_cr->immutable_fields], \@all_immutables, "Immutable fields remain unchanged";

        $test_poi_status->{svg} = 'none';
        cmp_bag [$client_cr->immutable_fields], [], "Immutable fields are reverted to empty";
    };

    subtest 'personal_details_locked status' => sub {
        my $args = {first_name => 'newname'};
        for ($client_cr, $client_mlt) {
            test_immutable_fields([], $test_user, 'the field is not immutble before authentication');
        }

        $client->status->set('personal_details_locked', 'system', 'just testing');
        for ($client_cr, $client_mlt) {
            test_immutable_fields([], $test_user, 'the field is not immutable before it is included in landing company config');
        }
        $changeable_fields->{personal_details_not_locked} = ['first_name'];
        for ($client_cr, $client_mlt) {
            test_immutable_fields([], $test_user, 'the field is immutable after being added to landing company config');
        }

        $client->status->clear_personal_details_locked;
        for ($client_cr, $client_mlt) {
            test_immutable_fields([], $test_user, 'the immutable field is editable again by removing the status flag');
        }
    };

    $mock_client->unmock_all;
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
            qw(salutation citizen tax_residence tax_identification_number first_name last_name date_of_birth residence address_line_1 address_city account_opening_reason);
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
            is $error->{error}, 'InputValidationFailed', 'error code is OK - InputValidationFailed';
            is $error->{details}->{field}, $field, "error details is OK - $field";
        }
    }
}

done_testing();
