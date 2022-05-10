use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;
use Test::Fatal qw(lives_ok exception);
use Test::MockTime qw(set_fixed_time restore_time);

use Date::Utility;
use MojoX::JSON::RPC::Client;
use POSIX qw/ ceil /;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Email qw(:no_event);
use BOM::Platform::Token;
use BOM::User::Client;
use BOM::User::Wallet;
use Email::Stuffer::TestLinks;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use BOM::Test::Helper::FinancialAssessment;
use BOM::Database::Model::OAuth;
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use utf8;

use IO::Pipe;

my $app = BOM::Database::Model::OAuth->new->create_app({
    name    => 'test',
    scopes  => '{read,admin,trade,payments}',
    user_id => 1
});
my $app_id = $app->{app_id};
isnt($app_id, 1, 'app id is not 1');    # There was a bug that the created token will be always app_id 1; We want to test that it is fixed.

my $fixed_time = Date::Utility->new('2018-02-15');
set_fixed_time($fixed_time->epoch);

my %emitted;
my $emit_data;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;

        $emit_data = $data;

        my $loginid = $data->{loginid};

        ok !$emitted{$type . '_' . $loginid}, "First (and hopefully unique) signup event for $loginid" if $type eq 'signup';

        $emitted{$type . '_' . $loginid}++;
    });

my %datadog_args;
my $mock_datadog = Test::MockModule->new('DataDog::DogStatsd::Helper');
$mock_datadog->mock(
    'stats_inc' => sub {
        my $key  = shift;
        my $args = shift;
        $datadog_args{$key} = $args;
    },
);

my $email = sprintf('Test%.5f@binary.com', rand(999));
my $rpc_ct;
my ($method, $params, $client_details);

$client_details = {
    salutation             => 'hello',
    last_name              => 'Vostrov' . rand(999),
    first_name             => 'Evgeniy' . rand(999),
    date_of_birth          => '1987-09-04',
    address_line_1         => 'Sovetskaya street',
    address_line_2         => 'home 1',
    address_city           => 'Samara',
    address_postcode       => '112233',
    phone                  => '+79272075932',
    secret_question        => 'test',
    secret_answer          => 'test',
    account_opening_reason => 'Speculative',
    citizen                => 'de',
    place_of_birth         => 'de',
};

$params = {
    language => 'EN',
    source   => $app_id,
    country  => 'ru',
    args     => {},
};

subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

$method = 'new_account_virtual';
subtest $method => sub {
    $params->{args}->{residence} = 'id';

    my @invalid_passwords = ('82341231258', '123abcasdda', '123ABC!@ASD', '1@3Abad', 'ABCdefdd');

    for my $pw (@invalid_passwords) {
        $params->{args}->{client_password}   = $pw;
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('PasswordError', 'If password is weak it should return error')
            ->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
            "If password ($pw) is weak it should return error_message");
    }

    $params->{args}->{client_password}   = '123Abcd!';
    $params->{args}->{verification_code} = 'wrong token';

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code is wrong it should return error')
        ->error_message_is('Your token has expired or is invalid.', 'If email verification_code is wrong it should return error_message');

    # first contact is limited within 30d, anytime earlier is less useful for marketing
    my $date_first_contact = Date::Utility->new->minus_time_interval('30d')->date_yyyymmdd;

    $params->{args}->{utm_source}         = 'google.com';
    $params->{args}->{utm_medium}         = 'email';
    $params->{args}->{utm_campaign}       = 'spring sale';
    $params->{args}->{gclid_url}          = 'FQdb3wodOkkGBgCMrlnPq42q8C';
    $params->{args}->{date_first_contact} = $date_first_contact;
    $params->{args}->{signup_device}      = 'mobile';
    $params->{args}->{email_consent}      = 1;

    my $expected_utm_data = {
        utm_campaign_id  => 111017190001,
        utm_content      => '2017_11_09_O_TGiving_NoSt_SDTest_NoCoup_2',
        utm_term         => 'MyLink123',
        utm_ad_id        => 'f521708e-db6e-478b-9731-8243a692c2d5',
        utm_adgroup_id   => 45637,
        utm_gl_client_id => 3541,
        utm_msclk_id     => 5,
        utm_fbcl_id      => 6,
        utm_adrollclk_id => 7,
    };
    # $params->{args}->{utm_ad_id} = $expected_utm_data->{utm_ad_id};
    map { $params->{args}->{$_} = $expected_utm_data->{$_} } keys %$expected_utm_data;
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    $params->{args}->{client_password} = $email;
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('PasswordError', 'If password is same as email, it should returns error')
        ->error_message_is('You cannot use your email address as your password.', 'If password is the same as email it should returns error_message');

    $email                               = lc $email;
    $params->{args}->{client_password}   = '123Abas!';
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
        ->result_value_is(sub { shift->{currency} },     'USD', 'It should return new account data')
        ->result_value_is(sub { ceil shift->{balance} }, 10000, 'It should return new account data');
    my $new_loginid = $rpc_ct->result->{client_id};

    ok $new_loginid =~ /^VRTC\d+/, 'new VR loginid';
    is $emit_data->{properties}->{type},    'trading', 'type=trading';
    is $emit_data->{properties}->{subtype}, 'virtual', 'subtype=virtual';

    my $token_db = BOM::Database::Model::AccessToken->new();
    my $tokens   = $token_db->get_all_tokens_by_loginid($new_loginid);
    is($tokens->[0]{info}, "App ID: $app_id", "token's app_id is correct");
    my $user = BOM::User->new(
        email => $email,
    );

    is $user->{utm_source},         'google.com',                 'utm registered as expected';
    is $user->{gclid_url},          'FQdb3wodOkkGBgCMrlnPq42q8C', 'gclid value returned as expected';
    is $user->{date_first_contact}, $date_first_contact, 'date first contact value returned as expected';
    is $user->{signup_device},      'mobile', 'signup_device value returned as expected';
    is $user->{email_consent},      1,        'email consent for new account is 1 for residence under svg';
    is_deeply decode_json_utf8($user->{utm_data}), $expected_utm_data, 'utm data registered as expected';

    my ($resp_loginid, $t, $uaf) =
        @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
    is $resp_loginid, $new_loginid, 'correct oauth token';

    my $oauth_token   = $rpc_ct->result->{oauth_token};
    my $refresh_token = $rpc_ct->result->{refresh_token};

    like $refresh_token, qr/^r1/, 'Got a refresh token';

    ok $emitted{"signup_$resp_loginid"}, "signup event emitted";

    subtest 'duplicate email' => sub {
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('duplicate email', 'Correct error code')->error_message_is(
            'Your provided email address is already in use by another Login ID. According to our terms and conditions, you may only register once through our site.',
            'Correct error message'
        );
    };

    subtest 'European client - de' => sub {
        my $vr_email = 'new_email' . rand(999) . '@binary.com';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $vr_email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{residence} = 'de';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },     'USD', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} }, 10000, 'It should return new account data');

        ok $emitted{'signup_' . $rpc_ct->result->{client_id}}, "signup event emitted";

        $user = BOM::User->new(
            email => $vr_email,
        );
        is $user->{email_consent}, 1, 'email consent for new account is 1 for european clients - de';

    };

    subtest 'European client - gb' => sub {
        my $vr_email = 'new_email' . rand(999) . '@binary.com';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $vr_email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{residence} = 'gb';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('invalid residence', 'gb is not allowed to sign up');
    };

    subtest 'non-pep self declaration' => sub {
        %datadog_args = ();
        # without non-pep declaration
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => 'new_email' . rand(999) . 'vr_non_pep@binary.com',
            created_for => 'account_opening'
        )->token;
        $params->{args}->{residence} = 'de';

        delete $params->{args}->{non_pep_declaration};
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('virtual account created without checking non-pep declaration');
        my $client = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});
        is $client->non_pep_declaration_time, undef, 'non_pep_declaration_time is empty for virtual account';

        # with non-pep declaration
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => 'new_email' . rand(999) . 'vr_non_pep@binary.com',
            created_for => 'account_opening'
        )->token;
        $params->{args}->{non_pep_declaration} = 1;
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('virtual account created with checking non-pep declaration');
        $client = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});
        is $client->non_pep_declaration_time, undef,
            'non_pep_self_declaration_time is empty for virtual accounts even when rpc is called with param set to 1';
    };

    subtest 'email consent given' => sub {
        my $vr_email = 'consent_given' . rand(999) . '@binary.com';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $vr_email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{residence}     = 'de';
        $params->{args}->{email_consent} = 1;
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },     'USD', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} }, 10000, 'It should return new account data');

        ok $emitted{'signup_' . $rpc_ct->result->{client_id}}, "signup event emitted";

        $user = BOM::User->new(
            email => $vr_email,
        );
        is $user->{email_consent}, 1, 'email consent is given';
    };

    subtest 'email consent not given' => sub {
        my $vr_email = 'not_consent' . rand(999) . '@binary.com';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $vr_email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{residence}     = 'de';
        $params->{args}->{email_consent} = 0;
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },     'USD', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} }, 10000, 'It should return new account data');

        ok $emitted{'signup_' . $rpc_ct->result->{client_id}}, "signup event emitted";

        $user = BOM::User->new(
            email => $vr_email,
        );
        is $user->{email_consent}, 0, 'email consent is not given';
    };

    subtest 'email consent undefined' => sub {
        my $vr_email = 'undefined_consent' . rand(999) . '@binary.com';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $vr_email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{residence} = 'de';
        delete $params->{args}->{email_consent};

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },     'USD', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} }, 10000, 'It should return new account data');

        ok $emitted{'signup_' . $rpc_ct->result->{client_id}}, "signup event emitted";

        $user = BOM::User->new(
            email => $vr_email,
        );
        is $user->{email_consent}, 1, 'email concent is accepted by default';
    };

    subtest 'invalid utm data' => sub {
        my $vr_email = 'invalid_utm_data' . rand(999) . '@binary.com';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $vr_email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{utm_content}  = '$content';
        $params->{args}->{utm_term}     = 'term2$';
        $params->{args}->{utm_campaign} = 'camp$ign2';

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },     'USD', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} }, 10000, 'It should return new account data');

        ok $emitted{'signup_' . $rpc_ct->result->{client_id}}, "signup event emitted";

        $user = BOM::User->new(
            email => $vr_email,
        );

        my $utm_data = decode_json_utf8($user->{utm_data});
        foreach my $key (keys $utm_data->%*) {
            if ($params->{args}->{$key} !~ /^[\w\s\.\-_]{1,100}$/) {
                is $utm_data->{$key}, undef, "$key is skipped as expected";
            } else {
                is $utm_data->{$key}, $params->{args}->{$key}, "$key has been set correctly";
            }
        }
    };
};

$method = 'new_account_real';
$params = {
    language => 'EN',
    source   => $app_id,
    country  => 'ru',
    args     => {},
};

subtest $method => sub {
    my ($user, $client, $vclient, $auth_token);

    subtest 'Initialization' => sub {
        lives_ok {
            # Make real client
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                email       => 'new_email' . rand(999) . '@binary.com',
            });
            $auth_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

            # Make virtual client with user
            my $password = 'Abcd33!@#';
            my $hash_pwd = BOM::User::Password::hashpw($password);
            $email = 'new_email' . rand(999) . '@binary.com';
            $user  = BOM::User->create(
                email    => $email,
                password => $hash_pwd
            );

            $vclient = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email       => $email,
            });

            $user->add_client($vclient);
        };
        'Initial users and clients';
    };

    subtest 'Auth client' => sub {
        $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('InvalidToken', 'It should return error: InvalidToken');

        $params->{token} = 'wrong token';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('InvalidToken', 'It should return error: InvalidToken');

        delete $params->{token};
        $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('InvalidToken', 'It should return error: InvalidToken');

        $params->{token} = $auth_token;

        {
            my $module = Test::MockModule->new('BOM::User::Client');
            $module->mock('new', sub { });

            $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('AuthorizationRequired', 'It should check auth');
        }
    };

    subtest 'Create new account' => sub {
        $emit_data = {};
        $params->{token} = BOM::Platform::Token::API->new->create_token($vclient->loginid, 'test token');

        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;
        isnt $result->{error}->{code}, 'InvalidAccount', 'No error with duplicate details but residence not provided so it errors out';

        $params->{args}->{residence}      = 'id';
        $params->{args}->{address_state}  = 'Sumatera';
        $params->{args}->{place_of_birth} = 'id';

        @{$params->{args}}{keys %$client_details} = values %$client_details;

        $params->{args}{citizen} = "at";

        # These are here because our test helper function "create_client" creates a virtual client with details such as first name which never happens in production. This causes the new_account_real call to fail as it checks against some details can't be changed but is checked against the details of the virtual account
        # $params->{args}{first_name} = $vclient->first_name;
        # $params->{args}{last_name} = $vclient->last_name;
        # $params->{args}{date_of_birth} = $vclient->date_of_birth;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('email unverified', 'It should return error if email unverified')
            ->error_message_is('Your email address is unverified.', 'It should return error if email unverified');

        $user->update_email_fields(email_verified => 1);

        $params->{args}->{phone} = 'a1234567890';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidPhone', 'Phone number could not contain alphabetic characters')
            ->error_message_is(
            'Please enter a valid phone number, including the country code (e.g. +15417541234).',
            'Phone number is invalid only if it contains alphabetic characters'
            );

        $params->{args}->{phone} = '1234256789';

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Deriv (SVG) LLC',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} }, 'svg', 'It should return new account data');

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^CR\d+$/, 'new CR loginid';
        is $emit_data->{properties}->{type},    'trading', 'type=trading';
        is $emit_data->{properties}->{subtype}, 'real',    'subtype=real';

        my $token_db = BOM::Database::Model::AccessToken->new();
        my $tokens   = $token_db->get_all_tokens_by_loginid($new_loginid);
        is($tokens->[0]{info}, "App ID: $app_id", "token's app_id is correct");

        my ($resp_loginid, $t, $uaf) =
            @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
        is $resp_loginid, $new_loginid, 'correct oauth token';

        my $new_client = BOM::User::Client->new({loginid => $new_loginid});
        $new_client->status->set('duplicate_account', 'system', 'reason');

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Deriv (SVG) LLC',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} },
            'svg', 'It should return new account data if one of the account is marked as duplicate');
        $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^CR\d+$/, 'new CR loginid';
        ok $emitted{"signup_$new_loginid"}, "signup event emitted";
        # check disabled case
        my $disabled_client = BOM::User::Client->new({loginid => $new_loginid});
        $disabled_client->status->set('disabled', 'system', 'reason');
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Deriv (SVG) LLC',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} },
            'svg', 'It should return new account data if one of the account is marked as disabled & account currency is not selected.');
        $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^CR\d+$/, 'new CR loginid';
        # check disabled but account currency selected case
        $new_client = BOM::User::Client->new({loginid => $new_loginid});

        $disabled_client->set_default_account("USD");
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('SetExistingAccountCurrency', 'correct error code.')
            ->error_message_is("Please set the currency for your existing account $new_loginid, in order to create more accounts.",
            'It should return expected error message');

        $new_client->set_default_account("USD");
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error;
        is $rpc_ct->result->{refresh_token}, undef, 'No refresh token generated for the second account';
        ok $rpc_ct->result->{oauth_token} =~ /^a1-.*/, 'OAuth token generated for the second account';
    };

    subtest 'Create multiple accounts in CR' => sub {
        $email = 'new_email' . rand(999) . '@binary.com';

        delete $params->{token};
        $params->{args}->{email}           = $email;
        $params->{args}->{client_password} = 'verylongDDD1!';

        $params->{args}->{residence}    = 'id';
        $params->{args}->{utm_source}   = 'google.com';
        $params->{args}->{utm_medium}   = 'email';
        $params->{args}->{utm_campaign} = 'spring sale';
        $params->{args}->{gclid_url}    = 'FQdb3wodOkkGBgCMrlnPq42q8C';
        delete $params->{args}->{non_pep_declaration};
        %datadog_args = ();

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        $rpc_ct->call_ok('new_account_virtual', $params)
            ->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },     'USD', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} }, 10000, 'It should return new account data');

        my $client_cr = {
            first_name    => 'James' . rand(999),
            last_name     => 'Brown' . rand(999),
            date_of_birth => '1960-01-02',
            phone         => sprintf("+792720756%02d", rand(99)),
        };

        @{$params->{args}}{keys %$client_cr} = values %$client_cr;

        $params->{token} = $rpc_ct->result->{oauth_token};

        $params->{args}->{currency} = 'USD';

        $params->{args}->{affiliate_token} = 'first';

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('create fiat currency account')
            ->result_value_is(sub { shift->{currency} }, 'USD', 'fiat currency account currency is USD');

        my $cl_usd = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});

        $params->{token} = $rpc_ct->result->{oauth_token};

        ok $cl_usd->non_pep_declaration_time, 'Non-pep self declaration time is set';
        $cl_usd->non_pep_declaration_time('2018-01-01');

        is $cl_usd->authentication_status, 'no', 'Client is not authenticated yet';

        $cl_usd->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $cl_usd->save;

        is $cl_usd->authentication_status, 'scans', 'Client is fully authenticated with scans';
        $cl_usd->save;

        is $cl_usd->myaffiliates_token, 'first', 'client affiliate token set succesfully';
        $params->{args}->{currency} = 'EUR';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error('cannot create second fiat currency account')
            ->error_code_is('CurrencyTypeNotAllowed', 'error code is CurrencyTypeNotAllowed');

        # Delete all params except currency. Info from prior account should be used
        $params->{args} = {'currency' => 'BTC'};
        $params->{args}->{affiliate_token} = 'second';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('create crypto currency account, reusing info')
            ->result_value_is(sub { shift->{currency} }, 'BTC', 'crypto account currency is BTC');

        sleep 2;

        my $loginid = $rpc_ct->result->{client_id};

        $rpc_ct->call_ok('get_account_status', {token => $params->{token}});

        my $is_authenticated = grep { $_ eq 'authenticated' } @{$rpc_ct->result->{status}};

        is $is_authenticated, 1, 'New client is also authenticated';

        my $cl_btc = BOM::User::Client->new({loginid => $loginid});

        is $cl_btc->myaffiliates_token, 'first', 'client affiliate token not changed';

        is($cl_btc->financial_assessment(), undef, 'new client has no financial assessment if previous client has none as well');

        is $client_cr->{$_}, $cl_btc->$_, "$_ is correct on created account" for keys %$client_cr;

        ok(defined($cl_btc->binary_user_id), 'BTC client has a binary user id');
        ok(defined($cl_usd->binary_user_id), 'USD client has a binary_user_id');
        is $cl_btc->binary_user_id, $cl_usd->binary_user_id, 'Both BTC and USD clients have the same binary user id';
        is $cl_btc->non_pep_declaration_time, '2018-01-01 00:00:00', 'Pep self-declaration time is the same for CR siblings';

        $params->{args}->{currency} = 'BTC';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error('cannot create another crypto currency account with same currency')
            ->error_code_is('DuplicateCurrency', 'error code is DuplicateCurrency');

        # Set financial assessment for default client before making a new account to check if new account inherits the financial assessment data
        my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
        $cl_usd->financial_assessment({
            data => encode_json_utf8($data),
        });
        $cl_usd->save();

        $params->{args}->{currency}            = 'LTC';
        $params->{args}->{citizen}             = 'af';
        $params->{args}->{place_of_birth}      = 'af';
        $params->{args}->{non_pep_declaration} = 1;

        $rpc_ct->call_ok($method, $params)->has_error()->error_code_is('CannotChangeAccountDetails')
            ->error_message_is('You may not change these account details.')->error_details_is({changed => ["citizen", "place_of_birth"]});

        delete $params->{args}->{place_of_birth};
        delete $params->{args}->{citizen};
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('create second crypto currency account')
            ->result_value_is(sub { shift->{currency} }, 'LTC', 'crypto account currency is LTC');

        my $cl_ltc = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});

        cmp_ok($cl_ltc->citizen, 'eq', $cl_usd->citizen, 'Citizenship cannot be changed');

        is_deeply(
            decode_json_utf8($cl_ltc->financial_assessment->{data}),
            decode_json_utf8($cl_usd->financial_assessment->{data}),
            "new client financial assessment is the same as old client financial_assessment"
        );

        $rpc_ct->call_ok('get_settings', {token => $rpc_ct->result->{oauth_token}})->result;
        cmp_ok($rpc_ct->result->{place_of_birth}, 'eq', $client_details->{place_of_birth}, 'place_of_birth cannot be changed');
    };
};

$method = 'new_account_maltainvest';
$params = {
    language => 'EN',
    source   => $app_id,
    country  => 'ru',
    args     => {
        'other_instruments_trading_frequency'  => '6-10 transactions in the past 12 months',
        'forex_trading_frequency'              => '0-5 transactions in the past 12 months',
        'education_level'                      => 'Secondary',
        'forex_trading_experience'             => '1-2 years',
        'binary_options_trading_experience'    => '1-2 years',
        'cfd_trading_experience'               => '1-2 years',
        'employment_industry'                  => 'Finance',
        'income_source'                        => 'Self-Employed',
        'other_instruments_trading_experience' => 'Over 3 years',
        'binary_options_trading_frequency'     => '40 transactions or more in the past 12 months',
        'set_financial_assessment'             => 1,
        'occupation'                           => 'Managers',
        'cfd_trading_frequency'                => '0-5 transactions in the past 12 months',
        'source_of_wealth'                     => 'Company Ownership',
        'estimated_worth'                      => '$100,000 - $250,000',
        'employment_status'                    => 'Self-Employed',
        'net_income'                           => '$25,000 - $50,000',
        'account_turnover'                     => '$50,001 - $100,000'
    },
};

subtest $method => sub {
    my ($user, $client, $auth_token);

    subtest 'Initialization' => sub {
        lives_ok {
            my $password = 'Abcd3s3!@';
            my $hash_pwd = BOM::User::Password::hashpw($password);
            $email = 'new_email' . rand(999) . '@binary.com';
            $user  = BOM::User->create(
                email    => $email,
                password => $hash_pwd
            );
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email       => $email,
                citizen     => '',
                first_name  => ''
            });
            $auth_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

            $user->add_client($client);
        }
        'Initial users and clients';
    };

    subtest 'Auth client' => sub {
        $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('InvalidToken', 'It should return error: InvalidToken');

        $params->{token} = 'wrong token';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('InvalidToken', 'It should return error: InvalidToken');

        delete $params->{token};
        $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('InvalidToken', 'It should return error: InvalidToken');

        $params->{token} = $auth_token;

        {
            my $module = Test::MockModule->new('BOM::User::Client');
            $module->mock('new', sub { });

            $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('AuthorizationRequired', 'It should check auth');
        }
    };

    subtest 'Create new account maltainvest' => sub {
        $params->{args}->{accept_risk} = 1;
        delete $params->{args}->{non_pep_declaration};
        %datadog_args = ();
        $params->{token} = $auth_token;

        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;
        is $result->{error}->{code}, 'PermissionDenied', 'It should return error if client residense does not fit for maltainvest';

        $client->residence('de');
        $client->save;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('email unverified', 'It should return error if email unverified')
            ->error_message_is('Your email address is unverified.', 'It should return error if email unverified');

        $user->update_email_fields(email_verified => 1);

        delete $params->{args}->{accept_risk};

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if client does not accept risk')
            ->error_message_is('Please provide complete details for your account.', 'It should return error if client does not accept risk');

        @{$params->{args}}{keys %$client_details} = values %$client_details;

        $params->{args}->{residence}  = 'de';
        $params->{args}->{first_name} = '';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if missing any details')
            ->error_message_is('Please provide complete details for your account.',
            'It should return error if missing details: "tax_residence", "tax_identification_number", "first_name", "residence"')
            ->error_details_is({missing => ["tax_residence", "tax_identification_number", "first_name"]});

        $params->{args}->{first_name}  = $client_details->{first_name};
        $params->{args}->{accept_risk} = 1;
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if missing any details')
            ->error_message_is('Please provide complete details for your account.',
            'It should return error if missing any details: "tax_residence", "tax_identification_number"')
            ->error_details_is({missing => ["tax_residence", "tax_identification_number"]});

        $params->{args}->{place_of_birth}            = "de";
        $params->{args}->{tax_residence}             = "de,nl";
        $params->{args}->{tax_identification_number} = "111222";

        $params->{args}->{citizen} = '';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if missing any details')
            ->error_message_is('Please provide complete details for your account.', 'It should return error if missing any details: citizen')
            ->error_details_is({missing => ["citizen"]});
        $params->{args}->{citizen} = 'at';

        my $mocked_client = Test::MockModule->new('BOM::User::Client');
        $mocked_client->redefine(residence => sub { return 'id' });
        $params->{args}->{residence} = 'id';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied', 'It should return error if residence does not fit with maltainvest')
            ->error_message_is('Permission denied.', 'It should return error if residence does not fit with maltainvest');
        $mocked_client->unmock_all;

        $params->{args}->{residence} = 'de';

        $client->citizen('');
        $client->save;

        $params->{args}->{citizen} = 'xx';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidCitizenship', 'Correct error code for invalid citizenship for maltainvest')
            ->error_message_is(
            'Sorry, our service is not available for your country of citizenship.',
            'Correct error message for invalid citizenship for maltainvest'
            );

        #if citizenship is from restricted country but residence is valid,it shouldn't throw any error
        $params->{args}->{citizen} = 'ir';

        $params->{args}->{phone} = 'a1234567890';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidPhone', 'Phone number could not contain alphabetic characters')
            ->error_message_is(
            'Please enter a valid phone number, including the country code (e.g. +15417541234).',
            'Phone number is invalid only if it contains alphabetic characters'
            );
        delete $params->{args}->{phone};

        $params->{args}->{citizen}   = 'de';
        $params->{args}->{residence} = 'de';
        $client->residence('de');
        $client->address_postcode('');
        $params->{args}->{address_postcode} = '';
        $client->save();

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Deriv Investments (Europe) Limited',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} }, 'maltainvest', 'It should return new account data');

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^MF\d+/, 'new MF loginid';

        my $cl = BOM::User::Client->new({loginid => $new_loginid});
        ok($cl->status->financial_risk_approval, 'For mf accounts we will set financial risk approval status');
        is $cl->non_pep_declaration_time, $fixed_time->datetime_yyyymmdd_hhmmss,
            'non_pep_declaration_time is auto-initialized with no non_pep_declaration in args';

        is $cl->status->crs_tin_information->{reason}, 'Client confirmed tax information', "CRS status is set";

        my ($resp_loginid, $t, $uaf) =
            @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
        is $resp_loginid, $new_loginid, 'correct oauth token';

        ok $emitted{"signup_$new_loginid"}, "signup event emitted";

        # check disabled case
        my $disabled_client = BOM::User::Client->new({loginid => $new_loginid});
        $disabled_client->status->set('disabled', 'system', 'reason');
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('NewAccountLimitReached', 'correct error code.')
            ->error_message_is('You have created all accounts available to you.', 'It should return expected error message');

        # check disabled but account currency selected case
        $disabled_client->set_default_account("USD");
        my $mock_user = Test::MockModule->new('BOM::User');
        $mock_user->redefine(bom_loginids => {return ($disabled_client->loginid)});
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('NewAccountLimitReached', 'correct error code.')
            ->error_message_is('You have created all accounts available to you.', 'It should return expected error message');
        $mock_user->unmock_all;
    };

    my $client_mlt;
    subtest 'Init MLT MF' => sub {
        lives_ok {
            my $password = 'Abcd33!@';
            my $hash_pwd = BOM::User::Password::hashpw($password);
            $email = 'new_email' . rand(999) . '@binary.com';
            $user  = BOM::User->create(
                email          => $email,
                password       => $hash_pwd,
                email_verified => 1,
            );
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code              => 'VRTC',
                email                    => $email,
                residence                => 'cz',
                non_pep_declaration_time => '2010-10-10',
            });
            is $client->non_pep_declaration_time, '2010-10-10 00:00:00',
                'non_pep_declaration_time equals the value of the arg passed to test create_account';
            $client->save;

            warning_like {
                like exception {
                    BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                        broker_code              => 'MLT',
                        email                    => $email,
                        residence                => 'cz',
                        secret_answer            => BOM::User::Utility::encrypt_secret_answer('mysecretanswer'),
                        non_pep_declaration_time => undef,
                    });
                },
                    qr/new row for relation "client" violates check constraint "check_non_pep_declaration_time"/,
                    'cannot create a real client with empty non_pep_declaration_time';
            }
            [qr/new row for relation "client" violates check constraint "check_non_pep_declaration_time"/],
                'expected database constraint violation warning';

            $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code              => 'MLT',
                email                    => $email,
                residence                => 'cz',
                address_state            => '',
                secret_answer            => BOM::User::Utility::encrypt_secret_answer('mysecretanswer'),
                non_pep_declaration_time => '2020-01-02',
            });
            $client_mlt->set_authentication('ID_DOCUMENT', {status => 'pass'});
            $client_mlt->save;
            $auth_token = BOM::Platform::Token::API->new->create_token($client_mlt->loginid, 'test token');
            $user->add_client($client);
            $user->add_client($client_mlt);
            $client_mlt->status->setnx('age_verification', 'system', 'Age verified client');
        }
        'Initial users and clients';
    };

    subtest 'Create new account maltainvest from MLT' => sub {
        $params->{args}->{accept_risk} = 1;
        $params->{token}               = $auth_token;
        $params->{args}->{residence}   = 'de';
        $params->{args}->{citizen}     = 'at';
        delete $params->{args}->{non_pep_declaration};
        %datadog_args = ();

        mailbox_clear();

        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_) =~ s/_// for qw/first_name last_name address_city/;
        $params->{args}->{phone}         = '+62 21 12345678';
        $params->{args}->{date_of_birth} = '1990-09-09';

        # We have to delete these fields here as our test helper function creates clients with different fields than what is declared above in this file. Should change this.
        delete $params->{args}->{secret_question};
        delete $params->{args}->{secret_answer};
        delete $params->{args}->{residence};
        my $result = $rpc_ct->call_ok($method, $params)->result;
        ok my $new_loginid = $result->{client_id}, 'New loginid is returned';

        my $token_db = BOM::Database::Model::AccessToken->new();
        my $tokens   = $token_db->get_all_tokens_by_loginid($new_loginid);
        is($tokens->[0]{info}, "App ID: $app_id", "token's app_id is correct");

        my $auth_token_mf = BOM::Platform::Token::API->new->create_token($new_loginid, 'test token');
        # make sure data is same, as in first account, regardless of what we have provided
        my $cl = BOM::User::Client->new({loginid => $new_loginid});
        is $client_mlt->$_, $cl->$_, "$_ is correct on created account" for qw/first_name last_name residence address_city phone date_of_birth/;
        $result = $rpc_ct->call_ok('get_settings', {token => $auth_token_mf})->result;
        is($result->{tax_residence}, 'de,nl', 'MF client has tax residence set');
        $result = $rpc_ct->call_ok('get_financial_assessment', {token => $auth_token_mf})->result;
        isnt(keys %$result, 0, 'MF client has financial assessment set');
        my $msg = mailbox_search(
            email   => 'compliance@deriv.com',
            subject => qr/\Qhas submitted the assessment test\E/
        );
        ok($msg, "Risk disclosure email received");
        is $cl->get_authentication('ID_DOCUMENT')->status, "pass", 'authentication method should be updated upon signup between MLT and MF';
        ok $cl->status->age_verification, 'age verification synced between mlt and mf.';
        is $cl->non_pep_declaration_time, $fixed_time->datetime_yyyymmdd_hhmmss,
            'non_pep_declaration_time is auto-initialized with no non_pep_declaration in args';

        cmp_ok $cl->non_pep_declaration_time, 'ne', $client_mlt->non_pep_declaration_time, 'non_pep declaration time is different from MLT account';
    };

    my $client_mx;
    subtest 'Init MX MF' => sub {
        lives_ok {
            my $password = 'Abcd33!@';
            my $hash_pwd = BOM::User::Password::hashpw($password);
            $email = 'mx_email' . rand(999) . '@binary.com';
            $user  = BOM::User->create(
                email          => $email,
                password       => $hash_pwd,
                email_verified => 1,
            );
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email       => $email,
                residence   => 'de',
            });
            $client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code   => 'MX',
                    email         => $email,
                    residence     => 'de',
                    secret_answer => BOM::User::Utility::encrypt_secret_answer('mysecretanswer')});
            $auth_token = BOM::Platform::Token::API->new->create_token($client_mx->loginid, 'test token');

            $user->add_client($client);
            $user->add_client($client_mx);

            is $client_mx->non_pep_declaration_time, $fixed_time->datetime_yyyymmdd_hhmmss,
                'non_pep_declaration_time is auto-initialized with no non_pep_declaration in args (test create_account call)';
            $client_mx->non_pep_declaration_time('2020-01-02');
            $client_mx->status->set('age_verification', 'system', 'Age verified client');
            $client_mx->save;
        }
        'Initial users and clients';
    };

    subtest 'Create new account maltainvest from MX' => sub {
        $params->{args}->{accept_risk} = 1;
        $params->{token}               = $auth_token;
        $params->{args}->{residence}   = 'de';
        delete $params->{args}->{non_pep_declaration};
        %datadog_args = ();

        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_) =~ s/_// for qw/first_name last_name address_city/;
        $params->{args}->{phone}         = '+62 21 12345678';
        $params->{args}->{date_of_birth} = '1990-09-09';

        $client_mx->status->set('unwelcome', 'system', 'test');
        my $result = $rpc_ct->call_ok($method, $params)->result;
        is $result->{error}->{code}, undef, 'Allow to open even if Client KYC is pending and status is unwelcome';

        my $new_loginid = $result->{client_id};
        my $token_db    = BOM::Database::Model::AccessToken->new();
        my $tokens      = $token_db->get_all_tokens_by_loginid($new_loginid);
        is($tokens->[0]{info}, "App ID: $app_id", "token's app_id is correct");

        my $auth_token_mf = BOM::Platform::Token::API->new->create_token($new_loginid, 'test token');

        # make sure data is same, as in first account, regardless of what we have provided
        my $cl = BOM::User::Client->new({loginid => $new_loginid});
        is $client_mx->$_, $cl->$_, "$_ is correct on created account" for qw/first_name last_name residence address_city phone date_of_birth/;

        $result = $rpc_ct->call_ok('get_settings', {token => $auth_token_mf})->result;
        is($result->{tax_residence}, 'de,nl', 'MF client has tax residence set');
        $result = $rpc_ct->call_ok('get_financial_assessment', {token => $auth_token_mf})->result;
        isnt(keys %$result, 0, 'MF client has financial assessment set');

        ok $emitted{"signup_$new_loginid"}, "signup event emitted";
        ok $cl->status->age_verification, 'age verification synced between mx and mf.';
        ok $cl->non_pep_declaration_time, 'non_pep_declaration_time is auto-initialized with no non_pep_declaration in args';
        cmp_ok $cl->non_pep_declaration_time, 'ne', '2020-01-02T00:00:00', 'non_pep declaration time is different from MLT account';
    };

    subtest 'Create a new account maltainvest from a virtual account' => sub {
        #create a virtual de client
        my $password = 'Abcd33!@';
        my $hash_pwd = BOM::User::Password::hashpw($password);
        $email = 'virtual_email' . rand(999) . '@binary.com';
        $user  = BOM::User->create(
            email          => $email,
            password       => $hash_pwd,
            email_verified => 1,
        );
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
            email       => $email,
            residence   => 'de',
        });
        $auth_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
        $user->add_client($client);

        $params->{args}->{accept_risk} = 1;
        $params->{token}               = $auth_token;
        $params->{args}->{residence}   = 'de';

        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_) =~ s/_// for qw/first_name last_name address_city/;
        $params->{args}->{phone}         = '+62 21 12345678';
        $params->{args}->{date_of_birth} = '1990-09-09';

        my $result = $rpc_ct->call_ok($method, $params)->result;
        ok $result->{client_id}, "Create an MF account from virtual account";

        ok $emitted{'signup_' . $result->{client_id}}, "signup event emitted";

        #create a virtual de client
        $email = 'virtual_germany_email' . rand(999) . '@binary.com';
        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_ . rand(9)) =~ s/_// for qw/first_name last_name residence address_city/;
        $params->{args}->{phone}         = '+62 21 12345999';
        $params->{args}->{date_of_birth} = '1990-09-09';

        $user = BOM::User->create(
            email          => $email,
            password       => $hash_pwd,
            email_verified => 1,
        );
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
            email       => $email,
            residence   => 'de',
        });
        $auth_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
        $user->add_client($client);

        $params->{token}                   = $auth_token;
        $params->{args}->{residence}       = 'de';
        $params->{args}->{secret_answer}   = 'test';
        $params->{args}->{secret_question} = 'test';

        $result = $rpc_ct->call_ok($method, $params)->result;
        ok $result->{client_id}, "Germany users can create MF account from the virtual account";

        ok $emitted{'signup_' . $result->{client_id}}, "signup event emitted";

        my $cl = BOM::User::Client->new({loginid => $result->{client_id}});
        ok $cl->non_pep_declaration_time,
            'non_pep_declaration_time is auto-initialized with no non_pep_declaration in args (test create_account call)';
    };

    subtest 'Create new account maltainvest without MLT' => sub {
        my $password = 'Abcd33!@';
        my $hash_pwd = BOM::User::Password::hashpw($password);
        #create a virtual cz client
        $email = 'virtual_de_email' . rand(999) . '@binary.com';
        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_ . rand(9)) =~ s/_// for qw/first_name last_name residence address_city/;
        $params->{args}->{phone}         = '+62 21 12098999';
        $params->{args}->{date_of_birth} = '1990-09-09';

        $user = BOM::User->create(
            email          => $email,
            password       => $hash_pwd,
            email_verified => 1,
        );
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
            email       => $email,
            residence   => 'at',
        });
        $auth_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
        $user->add_client($client);

        $params->{token}                   = $auth_token;
        $params->{args}->{residence}       = 'at';
        $params->{address_state}           = 'Salzburg';
        $params->{args}->{secret_answer}   = 'test';
        $params->{args}->{secret_question} = 'test';

        my $result = $rpc_ct->call_ok($method, $params)->has_no_error->result;
        ok $result->{client_id}, "Austrian users can create MF account from the virtual account";

        $auth_token = BOM::Platform::Token::API->new->create_token($result->{client_id}, 'test token');
    };

    subtest 'Create new gaming account from MF - not available' => sub {
        $params->{args}->{accept_risk} = 1;
        $params->{token}               = $auth_token;
        $params->{args}->{residence}   = 'at';
        $method                        = 'new_account_real';
        mailbox_clear();

        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_) =~ s/_// for qw/first_name last_name address_city/;
        $params->{args}->{phone}         = '+62 21 12345678';
        $params->{args}->{date_of_birth} = '1990-09-09';
        $params->{args}->{residence}     = 'at';
        # We have to delete these fields here as our test helper function creates clients with different fields than what is declared above in this file. Should change this.
        delete $params->{args}->{secret_question};
        delete $params->{args}->{secret_answer};

        $rpc_ct->call_ok($method, $params)->has_error->error_code_is('InvalidAccount')->error_message_is('Sorry, account opening is unavailable.');
    };
};

$method = 'new_account_real';

subtest 'Duplicate accounts are not created in race condition' => sub {
    my $params = {};

    $email                               = 'new_email' . rand(999) . '@binary.com';
    $params->{args}->{client_password}   = 'Abcd333@!';
    $params->{args}->{residence}         = 'id';
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
        ->result_value_is(sub { shift->{currency} },     'USD', 'It should return new account data')
        ->result_value_is(sub { ceil shift->{balance} }, 10000, 'It should return new account data');

    my $user = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}})->user;

    my $client_cr = {
        first_name    => 'James' . rand(999),
        last_name     => 'Brown' . rand(999),
        date_of_birth => '1960-01-02',
        phone         => sprintf("+792720756%02d", rand(99)),
    };
    @{$params->{args}}{keys %$client_cr} = values %$client_cr;
    $params->{token} = $rpc_ct->result->{oauth_token};
    $params->{args}->{currency} = 'USD';

    my $mocked_system = Test::MockModule->new('BOM::Config');
    $mocked_system->mock('on_production', sub { 1 });
    my $mocked_platform_redis = Test::MockModule->new('BOM::Platform::Redis');
    $mocked_platform_redis->mock(
        'acquire_lock',
        sub {
            return undef;
        });

    my $result = $rpc_ct->call_ok($method, $params)->{result};
    undef $mocked_platform_redis;

    is $result->{error}{code}, 'RateLimitExceeded', 'Account creation face error RateLimitExceeded in race condition';
};

$method = 'new_account_wallet';
$params = {
    language => 'EN',
    source   => $app_id,
    args     => {
        last_name        => 'Test' . rand(999),
        first_name       => 'Test1' . rand(999),
        date_of_birth    => '1987-09-04',
        address_line_1   => 'Sovetskaya street',
        address_city     => 'Samara',
        address_state    => 'Papua',
        address_postcode => '112233',
    },
};

subtest $method => sub {
    my ($user, $client, $auth_token);

    subtest 'Initialization' => sub {
        lives_ok {
            my $password = 'Abcd3s3!@';
            my $hash_pwd = BOM::User::Password::hashpw($password);
            $email = 'new_email' . rand(999) . '@binary.com';
            $user  = BOM::User->create(
                email    => $email,
                password => $hash_pwd
            );
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email       => $email,
                citizen     => 'de',
                residence   => 'de'
            });
            $auth_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

            $user->add_client($client);
        }
        'Initial users and clients';
    };

    my $mock_countries = Test::MockModule->new('Brands::Countries');

    subtest 'Create new wallet real' => sub {
        $emit_data = {};
        $params->{token} = $auth_token;

        $user->update_email_fields(email_verified => 1);

        my $app_config = BOM::Config::Runtime->instance->app_config;
        ok $app_config->system->suspend->wallets, 'wallets are suspended';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied',
            'It should return error code if wallet is unavailable in country of residence.')
            ->error_message_is('Wallet account creation is currently suspended.', 'Error message about service unavailability.');

        $app_config->system->suspend->wallets(0);

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidAccountRegion',
            'It should return error code if wallet is unavailable in country of residence.')
            ->error_message_is('Sorry, account opening is unavailable in your region.', 'Error message about service unavailability.');

        $mock_countries->redefine(wallet_company_for_country => 'wallet-svg');

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidState',
            'correct error code if address state doesnt match the country of residence')
            ->error_message_is('Sorry, the provided state is not valid for your country of residence.', 'Invalid state error message');

        $params->{args}->{address_state} = 'HH';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error code if missing any details')
            ->error_message_is('Please provide complete details for your account.', 'It should return error message if missing any details')
            ->error_details_is({missing => ["currency", "payment_method"]});

        $params->{args}->{payment_method} = 'fiat';
        $params->{args}->{currency}       = 'USD';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_no_error('If passed argumets are ok a new real wallet will be created successfully');
        $rpc_ct->result_value_is(sub { shift->{landing_company_shortcode} }, 'svg', 'It should return wallet landing company');

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^DW\d+/, 'new DW loginid';
        is $emit_data->{properties}->{type},    'wallet', 'type=wallet';
        is $emit_data->{properties}->{subtype}, 'real',   'subtype=real';

        my $wallet_client = BOM::User::Client->get_client_instance($new_loginid);
        isa_ok($wallet_client, 'BOM::User::Wallet', 'get_client_instance returns instance of wallet');
        ok($wallet_client->is_wallet,  'wallet client is_wallet is true');
        ok(!$wallet_client->can_trade, 'wallet client can_trade is false');
        is $wallet_client->residence, 'de', 'Residence is copied from the virtual account';

        is($wallet_client->payment_method, 'fiat', 'Payment method is set for wallet');
        ok $emitted{"signup_$new_loginid"}, "signup event emitted";

        $app_config->system->suspend->wallets(1);
    };

    $mock_countries->unmock_all;
};

subtest 'Empty phone number' => sub {
    my $email = 'empty+phone1241241@asdf.com';
    $params->{country}                   = 'br';
    $params->{args}->{residence}         = 'br';
    $params->{args}->{address_state}     = 'SP';
    $params->{args}->{client_password}   = '123Abas!';
    $params->{args}->{phone}             = '';
    $params->{args}->{first_name}        = 'i dont have';
    $params->{args}->{last_name}         = 'a phone number';
    $params->{args}->{date_of_birth}     = '1999-01-01';
    $params->{args}->{email}             = $email;
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    delete $params->{token};

    $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('vr account created successfully');
    my $vr_loginid = $rpc_ct->result->{client_id};

    $params->{token} = BOM::Platform::Token::API->new->create_token($vr_loginid, 'test token');
    $rpc_ct->call_ok('new_account_real', $params)->has_no_system_error->has_no_error('real account created successfully');

    my $real_loginid = $rpc_ct->result->{client_id};
    my $client       = BOM::User::Client->new({loginid => $real_loginid});
    is $client->phone, '', 'No phone set';
};

subtest 'Missing phone number' => sub {
    my $email = 'missing+phone1241241@asdf.com';
    $params->{country}                 = 'br';
    $params->{args}->{residence}       = 'br';
    $params->{args}->{client_password} = '123Abas!';
    $params->{args}->{first_name}      = 'i miss';
    $params->{args}->{last_name}       = 'my phone number';
    $params->{args}->{date_of_birth}   = '1999-01-02';
    $params->{args}->{email}           = $email;
    delete $params->{args}->{phone};
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    delete $params->{token};

    $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('vr account created successfully');
    my $vr_loginid = $rpc_ct->result->{client_id};

    $params->{token} = BOM::Platform::Token::API->new->create_token($vr_loginid, 'test token');
    $rpc_ct->call_ok('new_account_real', $params)->has_no_system_error->has_no_error('real account created successfully');

    my $real_loginid = $rpc_ct->result->{client_id};
    my $client       = BOM::User::Client->new({loginid => $real_loginid});
    is $client->phone, '', 'No phone set';
};

subtest 'Repeating phone number' => sub {
    my $email = 'repeating+phone@asdf.com';
    $params->{country}                   = 'br';
    $params->{args}->{residence}         = 'br';
    $params->{args}->{client_password}   = '123Abas!';
    $params->{args}->{first_name}        = 'i repeat';
    $params->{args}->{last_name}         = 'my phone number';
    $params->{args}->{date_of_birth}     = '1999-01-02';
    $params->{args}->{email}             = $email;
    $params->{args}->{phone}             = '111111111';
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    delete $params->{token};

    $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('vr account created successfully');
    my $vr_loginid = $rpc_ct->result->{client_id};

    $params->{token} = BOM::Platform::Token::API->new->create_token($vr_loginid, 'test token');
    $rpc_ct->call_ok('new_account_real', $params)->has_no_system_error->has_error->error_code_is('InvalidPhone', 'Repeating digits are not valid')
        ->error_message_is('Please enter a valid phone number, including the country code (e.g. +15417541234).',
        "Invalid phone number provided (repeated digits)");
};

subtest 'Forbidden postcodes' => sub {
    my $idauth_mock = Test::MockModule->new('BOM::Platform::Client::IDAuthentication');
    $idauth_mock->mock(
        'run_validation',
        sub {
            return 1;
        });

    my $password = 'Abcd33!@';
    my $hash_pwd = BOM::User::Password::hashpw($password);
    my $email    = 'the_forbidden_one' . rand(999) . '@binary.com';
    my $user     = BOM::User->create(
        email          => $email,
        password       => $hash_pwd,
        email_verified => 1,
    );
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => $email,
        residence   => 'gb',
    });

    my $auth_token = BOM::Platform::Token::API->new->create_token($client_vr->loginid, 'test token');
    $params->{country} = 'gb';
    $params->{args}    = {
        residence                              => 'gb',
        first_name                             => 'mr family',
        last_name                              => 'man',
        date_of_birth                          => '1999-01-02',
        email                                  => $email,
        phone                                  => '+15417541234',
        salutation                             => 'hello',
        citizen                                => 'gb',
        'other_instruments_trading_frequency'  => '6-10 transactions in the past 12 months',
        'forex_trading_frequency'              => '0-5 transactions in the past 12 months',
        'education_level'                      => 'Secondary',
        'forex_trading_experience'             => '1-2 years',
        'binary_options_trading_experience'    => '1-2 years',
        'cfd_trading_experience'               => '1-2 years',
        'employment_industry'                  => 'Finance',
        'income_source'                        => 'Self-Employed',
        'other_instruments_trading_experience' => 'Over 3 years',
        'binary_options_trading_frequency'     => '40 transactions or more in the past 12 months',
        'set_financial_assessment'             => 1,
        'occupation'                           => 'Managers',
        'cfd_trading_frequency'                => '0-5 transactions in the past 12 months',
        'source_of_wealth'                     => 'Company Ownership',
        'estimated_worth'                      => '$100,000 - $250,000',
        'employment_status'                    => 'Self-Employed',
        'net_income'                           => '$25,000 - $50,000',
        'account_turnover'                     => '$50,001 - $100,000',
        'tax_residence'                        => 'gb',
        'tax_identification_number'            => 'E1241241',
        'account_opening_reason'               => 'Speculative',
    };
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_vr->loginid, 'test token');

    $params->{args}->{address_postcode} = 'JE2';
    $rpc_ct->call_ok('new_account_maltainvest', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidAccount', 'InvalidAccount (used to be Invalid Jersey postcode)');

    $params->{args}->{address_postcode} = 'EA1 C1A1';

    $rpc_ct->call_ok('new_account_maltainvest', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidAccount', 'InvalidAccount (used to be a valid request)');

};

subtest 'Italian TIN test' => sub {
    subtest 'Old format' => sub {
        my $idauth_mock = Test::MockModule->new('BOM::Platform::Client::IDAuthentication');
        $idauth_mock->mock(
            'run_validation',
            sub {
                return 1;
            });

        my $password = 'Alienbatata20';
        my $hash_pwd = BOM::User::Password::hashpw($password);
        my $email    = 'bat2021' . rand(999) . '@binary.com';
        my $user     = BOM::User->create(
            email          => $email,
            password       => $hash_pwd,
            email_verified => 1,
        );
        my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
            email       => $email,
            residence   => 'it',
        });

        my $auth_token = BOM::Platform::Token::API->new->create_token($client_vr->loginid, 'test token');

        $params->{country}                 = 'it';
        $params->{args}->{residence}       = 'it';
        $params->{args}->{client_password} = $hash_pwd;
        $params->{args}->{subtype}         = 'real';
        $params->{args}->{first_name}      = 'Josue Lee';
        $params->{args}->{last_name}       = 'King';
        $params->{args}->{date_of_birth}   = '1989-09-01';
        $params->{args}->{email}           = $email;
        $params->{args}->{phone}           = '+393678917832';
        $params->{args}->{salutation}      = 'Op';
        $params->{args}->{citizen}         = 'it';
        $params->{args}->{accept_risk}     = 1;
        $params->{token}                   = $auth_token;

        $params->{args} = {
            $params->{args}->%*,
            'other_instruments_trading_frequency'  => '3-4 transactions in the past 9 months',
            'forex_trading_frequency'              => '19-29 transactions in the past 11',
            'education_level'                      => 'Tecnical',
            'forex_trading_experience'             => '5 years',
            'binary_options_trading_experience'    => '8 years',
            'cfd_trading_experience'               => '3 years',
            'employment_industry'                  => 'not Construction',
            'income_source'                        => 'employed',
            'other_instruments_trading_experience' => 'Over 6 years',
            'binary_options_trading_frequency'     => '15 transactions or more in the past 2 months',
            'set_financial_assessment'             => 1,
            'occupation'                           => 'Student',
            'cfd_trading_frequency'                => '8-9 transactions in the past 4 months',
            'source_of_wealth'                     => 'Not company Owner',
            'estimated_worth'                      => '$150,000 - $250,000',
            'employment_status'                    => 'Not Self-Employed',
            'net_income'                           => '$10,000 - $15,000',
            'account_turnover'                     => '$20,000 - $90,000',
            'tax_residence'                        => 'it',
            'tax_identification_number'            => 'MRTSVT79M29F899P',
            'account_opening_reason'               => 'Speculative',
        };

        my $result =
            $rpc_ct->call_ok('new_account_maltainvest', $params)->has_no_system_error->has_no_error('it mf account created successfully')->result;
        ok $result->{client_id}, 'got a client id';
    };

    subtest 'New format' => sub {
        my $idauth_mock = Test::MockModule->new('BOM::Platform::Client::IDAuthentication');
        $idauth_mock->mock(
            'run_validation',
            sub {
                return 1;
            });

        my $password = 'Alienbatata20';
        my $hash_pwd = BOM::User::Password::hashpw($password);
        my $email    = 'batata2020' . rand(999) . '@binary.com';
        my $user     = BOM::User->create(
            email          => $email,
            password       => $hash_pwd,
            email_verified => 1,
        );
        my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
            email       => $email,
            residence   => 'it',
        });

        my $auth_token = BOM::Platform::Token::API->new->create_token($client_vr->loginid, 'test token');

        $params->{country}                 = 'it';
        $params->{args}->{residence}       = 'it';
        $params->{args}->{client_password} = $hash_pwd;
        $params->{args}->{subtype}         = 'real';
        $params->{args}->{first_name}      = 'Joseph Batata';
        $params->{args}->{last_name}       = 'Junior';
        $params->{args}->{date_of_birth}   = '1997-01-01';
        $params->{args}->{email}           = $email;
        $params->{args}->{phone}           = '+393678916732';
        $params->{args}->{salutation}      = 'Hi';
        $params->{args}->{citizen}         = 'it';
        $params->{args}->{accept_risk}     = 1;
        $params->{token}                   = $auth_token;

        $params->{args} = {
            $params->{args}->%*,
            'other_instruments_trading_frequency'  => '4-5 transactions in the past 4 months',
            'forex_trading_frequency'              => '11-39 transactions in the past 12',
            'education_level'                      => 'University',
            'forex_trading_experience'             => '2 years',
            'binary_options_trading_experience'    => '3 years',
            'cfd_trading_experience'               => '6 years',
            'employment_industry'                  => 'Construction',
            'income_source'                        => 'Not employed',
            'other_instruments_trading_experience' => 'Over 6 years',
            'binary_options_trading_frequency'     => '80 transactions or more in the past 8 months',
            'set_financial_assessment'             => 1,
            'occupation'                           => 'Boss',
            'cfd_trading_frequency'                => '4-6 transactions in the past 9 months',
            'source_of_wealth'                     => 'Not company Owner',
            'estimated_worth'                      => '$200,000 - $250,000',
            'employment_status'                    => 'Self-Employed',
            'net_income'                           => '$10,000 - $25,000',
            'account_turnover'                     => '$30,000 - $90,000',
            'tax_residence'                        => 'it',
            'tax_identification_number'            => 'MRTSVT79M29F8P9P',
            'account_opening_reason'               => 'Income Earning',
        };

        my $result =
            $rpc_ct->call_ok('new_account_maltainvest', $params)->has_no_system_error->has_no_error('it mf account created successfully')->result;
        ok $result->{client_id}, 'got a client id';
    };

    subtest 'TIN with wrong format' => sub {
        my $idauth_mock = Test::MockModule->new('BOM::Platform::Client::IDAuthentication');
        $idauth_mock->mock(
            'run_validation',
            sub {
                return 1;
            });

        my $password = 'Allison90';
        my $hash_pwd = BOM::User::Password::hashpw($password);
        my $email    = 'Allison2020' . rand(999) . '@binary.com';
        my $user     = BOM::User->create(
            email          => $email,
            password       => $hash_pwd,
            email_verified => 1,
        );
        my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
            email       => $email,
            residence   => 'it',
        });

        my $auth_token = BOM::Platform::Token::API->new->create_token($client_vr->loginid, 'test token');

        $params->{country}                 = 'it';
        $params->{args}->{residence}       = 'it';
        $params->{args}->{client_password} = $hash_pwd;
        $params->{args}->{subtype}         = 'real';
        $params->{args}->{first_name}      = 'Allison Laura';
        $params->{args}->{last_name}       = 'Sean';
        $params->{args}->{date_of_birth}   = '1997-01-01';
        $params->{args}->{email}           = $email;
        $params->{args}->{phone}           = '+393678916702';
        $params->{args}->{salutation}      = 'Helloo';
        $params->{args}->{citizen}         = 'it';
        $params->{args}->{accept_risk}     = 1;
        $params->{token}                   = $auth_token;

        $params->{args} = {
            $params->{args}->%*,
            'other_instruments_trading_frequency'  => '3-4 transactions in the past 6 months',
            'forex_trading_frequency'              => '21-40 transactions in the past 8',
            'education_level'                      => 'University',
            'forex_trading_experience'             => '4 years',
            'binary_options_trading_experience'    => '7 years',
            'cfd_trading_experience'               => '4 years',
            'employment_industry'                  => 'Construction Industry',
            'income_source'                        => 'employed',
            'other_instruments_trading_experience' => 'Over 9 years',
            'binary_options_trading_frequency'     => '30 transactions or more in the past 3 months',
            'set_financial_assessment'             => 1,
            'occupation'                           => 'Not Boss',
            'cfd_trading_frequency'                => '7-9 transactions in the past 11 months',
            'source_of_wealth'                     => 'Not company Owner',
            'estimated_worth'                      => '$100,000 - $250,000',
            'employment_status'                    => 'Self-Employed',
            'net_income'                           => '$15,000 - $25,000',
            'account_turnover'                     => '$40,000 - $90,000',
            'tax_residence'                        => 'it',
            'tax_identification_number'            => 'MRTSVT79M29F8_9P',
            'account_opening_reason'               => 'Hedging',
        };

        my $result =
            $rpc_ct->call_ok('new_account_maltainvest', $params)->has_no_system_error->has_no_error('it mf account created successfully')->result;
        ok $result->{client_id}, 'got a client id';
    };
};

done_testing();
