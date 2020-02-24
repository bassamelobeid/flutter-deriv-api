use utf8;
binmode STDOUT, ':utf8';

use strict;
use warnings;

use Test::MockTime;
use Test::More qw( no_plan );
use Test::Exception;
use Test::MockModule;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Date::Utility;
my $login_id = 'CR0022';
my $client;

subtest "Client load and saving." => sub {
    plan tests => 43;
    # create client object
    lives_ok { $client = BOM::User::Client->new({'loginid' => $login_id}); }
    "Can create client object 'BOM::User::Client::get_instance({'loginid' => $login_id})'";

    isa_ok($client, 'BOM::User::Client');
    is($client->loginid, $login_id, 'Test $client->loginid');
    is(
        $client->first_name,
        '†•…‰™œŠŸž€ΑΒΓΔΩαβγδωАБВГДабвгд∀∂∈ℝ∧∪≡∞↑↗↨↻⇣┐┼╔╘░►☺',
        'Test $client->first_name'
    );
    is($client->last_name, '♀ﬁ�⑀₂ἠḂӥẄɐː⍎אԱა Καλημέρα κόσμε, コンニチハ', 'Test $client->last_name');
    is($client->password, '48elKjgSSiaeD5v233716ab5', 'Test $client->password');

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
    $client->set_authentication('ID_NOTARIZED')->status('pass');
    ok($client->fully_authenticated(), 'CR0006 - fully authenticated as it has ID_NOTARIZED');

    lives_ok { $client = BOM::User::Client->new({'loginid' => 'CR0007'}); }
    "Can create client object 'BOM::User::Client::get_instance({'loginid' => CR0007})'";
    is($client->fully_authenticated(), 1, "CR0007 - fully authenticated");

    my $client_details = {
        'loginid'          => 'CR5089',
        'email'            => 'felix@regentmarkets.com',
        'client_password'  => '960f984285701c6d8dba5dc71c35c55c0397ff276b06423146dde88741ddf1af',
        'broker_code'      => 'CR',
        'allow_login'      => 1,
        'last_name'        => 'The cat',
        'first_name'       => 'Felix',
        'date_of_birth'    => '1951-01-01',
        'address_postcode' => '47650',
        'address_state'    => '',
        'secret_question'  => 'Name of your pet',
        'date_joined'      => '2007-11-29',
        'email'            => 'felix@regentmarkets.com',
        'latest_environment' =>
            '31-May-10 02h09GMT 99.99.99.63 Mozilla 5.0 (X11; U; Linux i686; en-US; rv:1.9.2.3) Gecko 20100401 Firefox 3.6.3 LANG=EN SKIN=',
        'address_city' => 'Subang Jaya',
        'address_line_1' =>
            '†•…‰™œŠŸž€ΑΒΓΔΩαβγδωАБВГДабвгд∀∂∈ℝ∧∪≡∞↑↗↨↻⇣┐┼╔╘░►☺',
        'secret_answer'         => '::ecp::52616e646f6d495633363368676674792dd36b78f1d98017',
        'address_line_2'        => '♀ﬁ�⑀₂ἠḂӥẄɐː⍎אԱა Καλημέρα κόσμε, コンニチハ',
        'restricted_ip_address' => '',
        'loginid'               => 'CR5089',
        'salutation'            => 'Mr',
        'last_name'             => 'The cat',
        'gender'                => 'm',
        'phone'                 => '21345678',
        'residence'             => 'af',
        'comment'               => '',
        'first_name'            => 'Felix',
        'citizen'               => 'br'
    };

    $client = BOM::User::Client->rnew(%$client_details);

    is($client->loginid,    $client_details->{'loginid'},         'compare loginid between client object instantize with client hash ref');
    is($client->broker,     $client_details->{'broker_code'},     'compare broker between client object instantize with client hash ref');
    is($client->password,   $client_details->{'client_password'}, 'compare password between client object instantize with client hash ref');
    is($client->email,      $client_details->{'email'},           'compare email between client object instantize with client hash ref');
    is($client->last_name,  $client_details->{'last_name'},       'compare last_name between client object instantize with client hash ref');
    is($client->first_name, $client_details->{'first_name'},      'compare first_name between client object instantize with client hash ref');

    is(length($client->address_1), 50, "treats Unicode chars correctly");
    is(length($client->address_2), 37, "treats Unicode chars correctly");

    is($client->date_of_birth, $client_details->{'date_of_birth'}, 'compare date_of_birth between client object instantize with client hash ref');
    is(
        $client->secret_question,
        $client_details->{'secret_question'},
        'compare secret_question between client object instantize with client hash ref'
    );
    is($client->date_joined =~ /^$client_details->{'date_joined'}/, 1, 'compare date_joined between client object instantize with client hash ref');
    is($client->email, $client_details->{'email'}, 'compare email between client object instantize with client hash ref');
    is(
        $client->latest_environment,
        $client_details->{'latest_environment'},
        'compare latest_environment between client object instantize with client hash ref'
    );
    is($client->secret_answer, $client_details->{'secret_answer'}, 'compare secret_answer between client object instantize with client hash ref');
    is(
        $client->restricted_ip_address,
        $client_details->{'restricted_ip_address'},
        'compare restricted_ip_address between client object instantize with client hash ref'
    );
    is($client->loginid,    $client_details->{'loginid'},    'compare loginid between client object instantize with client hash ref');
    is($client->salutation, $client_details->{'salutation'}, 'compare salutation between client object instantize with client hash ref');
    is($client->last_name,  $client_details->{'last_name'},  'compare last_name between client object instantize with client hash ref');
    is($client->phone,      $client_details->{'phone'},      'compare phone between client object instantize with client hash ref');
    is($client->residence,  $client_details->{'residence'},  'compare residence between client object instantize with client hash ref');
    is($client->first_name, $client_details->{'first_name'}, 'compare first_name between client object instantize with client hash ref');
    is($client->citizen,    $client_details->{'citizen'},    'compare citizen between client object instantize with client hash ref');

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

    $client = BOM::User::Client->rnew(%$client_details);

    is($client->loginid,    $client_details->{'loginid'},         'compare loginid between client object instantize with another client hash ref');
    is($client->broker,     $client_details->{'broker_code'},     'compare broker between client object instantize with another client hash ref');
    is($client->password,   $client_details->{'client_password'}, 'compare password between client object instantize with another client hash ref');
    is($client->email,      $client_details->{'email'},           'compare email between client object instantize with client another hash ref');
    is($client->last_name,  $client_details->{'last_name'},       'compare last_name between client object instantize with another client hash ref');
    is($client->first_name, $client_details->{'first_name'},      'compare first_name between client object instantize with another client hash ref');
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
        my $value_hash = $data_dob_invalid{$key};
        is($dob_result_hash->{error}, $value_hash->{error}, "validate_dob gets error $key");
    }
};

subtest "format and validate" => sub {

    my $args = {first_name => ' newname '};
    is $client->validate_fields_immutable($args)->{details}, 'first_name', 'validate_fields_immutable';

    $client->format_input_details($args);
    is $args->{first_name}, 'newname', 'trim firstname';

    $args = {phone => 123456};
    is $client->format_input_details($args)->{error}, 'InvalidPhone', 'InvalidPhone';

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

};
