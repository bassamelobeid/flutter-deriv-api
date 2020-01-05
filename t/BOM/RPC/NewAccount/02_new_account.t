use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;
use Test::Fatal qw(lives_ok);

use Date::Utility;
use MojoX::JSON::RPC::Client;
use POSIX qw/ ceil /;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Email qw(:no_event);
use BOM::Platform::Token;
use BOM::User::Client;
use Email::Stuffer::TestLinks;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use BOM::Test::Helper::FinancialAssessment;
use BOM::Database::Model::OAuth;
use BOM::Platform::Token::API;
use utf8;
my $app = BOM::Database::Model::OAuth->new->create_app({
    name    => 'test',
    scopes  => '{read,admin,trade,payments}',
    user_id => 1
});
my $app_id = $app->{app_id};
isnt($app_id, 1, 'app id is not 1');    # There was a bug that the created token will be always app_id 1; We want to test that it is fixed.
my %emitted;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;
        $emitted{$type . '_' . $data->{loginid}}++;
    });

my $email = 'test' . rand(999) . '@binary.com';
my ($t, $rpc_ct);
my ($method, $params, $client_details);

$client_details = {
    salutation             => 'hello',
    last_name              => 'Vostrov' . rand(999),
    first_name             => 'Evgeniy' . rand(999),
    date_of_birth          => '1987-09-04',
    address_line_1         => 'Sovetskaya street',
    address_line_2         => 'home 1',
    address_city           => 'Samara',
    address_state          => 'Samara',
    address_postcode       => '112233',
    phone                  => '+79272075932',
    secret_question        => 'test',
    secret_answer          => 'test',
    account_opening_reason => 'Speculative',
    citizen                => 'de',
    place_of_birth         => "de",

};

$params = {
    language => 'EN',
    source   => $app_id,
    country  => 'ru',
    args     => {},
};

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
        $rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

$method = 'new_account_virtual';
subtest $method => sub {

    my @invalid_passwords = ('123456', '123abc', '123ABC', '123Ab', 'ABCdef');

    for my $pw (@invalid_passwords) {
        $params->{args}->{client_password} = $pw;
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('PasswordError', 'If password is weak it should return error')
            ->error_message_is('Password should be at least six characters, including lower and uppercase letters with numbers.',
            'If password is weak it should return error_message');
    }

    $params->{args}->{client_password}   = '123Ab!';
    $params->{args}->{verification_code} = 'wrong token';

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code is wrong it should return error')
        ->error_message_is('Your token has expired or is invalid.', 'If email verification_code is wrong it should return error_message');

    # first contact is limited within 30d, anytime earlier is less useful for marketing
    my $date_first_contact = Date::Utility->new->minus_time_interval('30d')->date_yyyymmdd;

    $params->{args}->{residence}          = 'id';
    $params->{args}->{utm_source}         = 'google.com';
    $params->{args}->{utm_medium}         = 'email';
    $params->{args}->{utm_campaign}       = 'spring sale';
    $params->{args}->{gclid_url}          = 'FQdb3wodOkkGBgCMrlnPq42q8C';
    $params->{args}->{date_first_contact} = $date_first_contact;
    $params->{args}->{signup_device}      = 'mobile';

    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
        ->result_value_is(sub { shift->{currency} },     'USD', 'It should return new account data')
        ->result_value_is(sub { ceil shift->{balance} }, 10000, 'It should return new account data');
    my $new_loginid = $rpc_ct->result->{client_id};

    ok $new_loginid =~ /^VRTC\d+/, 'new VR loginid';

    my $token_db = BOM::Database::Model::AccessToken->new();
    my $tokens   = $token_db->get_all_tokens_by_loginid($new_loginid);
    is($tokens->[0]{info}, "App ID: $app_id", "token's app_id is correct");
    my $user = BOM::User->new(
        email => $email,
    );

    is $user->{utm_source}, 'google.com', 'utm registered as expected';
    is $user->{gclid_url}, 'FQdb3wodOkkGBgCMrlnPq42q8C', 'gclid value returned as expected';
    is $user->{date_first_contact}, $date_first_contact, 'date first contact value returned as expected';
    is $user->{signup_device}, 'mobile', 'signup_device value returned as expected';
    is $user->{email_consent}, 1,        'email consent for new account is 1 for residence under svg';

    my ($resp_loginid, $t, $uaf) =
        @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
    is $resp_loginid, $new_loginid, 'correct oauth token';

    ok $emitted{"register_details_$resp_loginid"}, "register_details event emitted";

    ok $emitted{"signup_$resp_loginid"}, "signup event emitted";

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

        ok $emitted{'register_details_' . $rpc_ct->result->{client_id}}, "register_details event emitted";

        ok $emitted{'signup_' . $rpc_ct->result->{client_id}}, "signup event emitted";

        $user = BOM::User->new(
            email => $vr_email,
        );
        is $user->{email_consent}, 0, 'email consent for new account is 0 for european clients - de';

    };

    subtest 'European client - gb' => sub {
        my $vr_email = 'new_email' . rand(999) . '@binary.com';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $vr_email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{residence} = 'gb';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },     'USD', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} }, 10000, 'It should return new account data');

        ok $emitted{'register_details_' . $rpc_ct->result->{client_id}}, "register_details event emitted";

        ok $emitted{'signup_' . $rpc_ct->result->{client_id}}, "signup event emitted";

        $user = BOM::User->new(
            email => $vr_email,
        );
        is $user->{email_consent}, 0, 'email consent for new account is 0 for european clients - gb';
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
            my $password = 'jskjd8292922';
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

    subtest 'Create new account' => sub {
        $params->{token} = BOM::Platform::Token::API->new->create_token($vclient->loginid, 'test token');

        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;
        isnt $result->{error}->{code}, 'InvalidAccount', 'No error with duplicate details but residence not provided so it errors out';

        $params->{args}->{residence}      = 'id';
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

        $params->{args}->{phone} = '1234567890';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidPhone', 'It should return error if phone cannot be formatted to E.123')
            ->error_message_is('Please enter a valid phone number, including the country code (e.g. +15417541234).',
            'It should return expected error message');
        delete $params->{args}->{phone};

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Binary (SVG) Ltd.',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} }, 'svg', 'It should return new account data');

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^CR\d+$/, 'new CR loginid';

        my $token_db = BOM::Database::Model::AccessToken->new();
        my $tokens   = $token_db->get_all_tokens_by_loginid($new_loginid);
        is($tokens->[0]{info}, "App ID: $app_id", "token's app_id is correct");

        ok $emitted{"register_details_$new_loginid"}, "register_details event emitted";

        my ($resp_loginid, $t, $uaf) =
            @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
        is $resp_loginid, $new_loginid, 'correct oauth token';

        my $new_client = BOM::User::Client->new({loginid => $new_loginid});
        $new_client->status->set('duplicate_account', 'system', 'reason');

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Binary (SVG) Ltd.',
            'It should return new account data'
            )->result_value_is(sub { shift->{landing_company_shortcode} },
            'svg', 'It should return new account data if one of the account is marked as duplicate');
        $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^CR\d+$/, 'new CR loginid';
        ok $emitted{"signup_$new_loginid"}, "signup event emitted";
    };

    subtest 'Create multiple accounts in CR' => sub {

        $email = 'new_email' . rand(999) . '@binary.com';

        $params->{args}->{client_password} = 'verylongandhardpasswordDDD1!';

        $params->{args}->{residence}    = 'id';
        $params->{args}->{utm_source}   = 'google.com';
        $params->{args}->{utm_medium}   = 'email';
        $params->{args}->{utm_campaign} = 'spring sale';
        $params->{args}->{gclid_url}    = 'FQdb3wodOkkGBgCMrlnPq42q8C';

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

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('create fiat currency account')
            ->result_value_is(sub { shift->{currency} }, 'USD', 'fiat currency account currency is USD');

        my $cl_usd = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});

        $params->{token} = $rpc_ct->result->{oauth_token};

        is $cl_usd->authentication_status, 'no', 'Client is not authenticated yet';

        $cl_usd->set_authentication('ID_DOCUMENT')->status('pass');
        $cl_usd->save;
        is $cl_usd->authentication_status, 'scans', 'Client is fully authenticated with scans';

        $params->{args}->{currency} = 'EUR';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error('cannot create second fiat currency account')
            ->error_code_is('CurrencyTypeNotAllowed', 'error code is CurrencyTypeNotAllowed');

        # Delete all params except currency. Info from prior account should be used
        $params->{args} = {'currency' => 'BTC'};
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('create crypto currency account, reusing info')
            ->result_value_is(sub { shift->{currency} }, 'BTC', 'crypto account currency is BTC');

        sleep 2;

        my $loginid = $rpc_ct->result->{client_id};

        $rpc_ct->call_ok('get_account_status', {token => $params->{token}});

        my $is_authenticated = grep { $_ eq 'authenticated' } @{$rpc_ct->result->{status}};

        is $is_authenticated, 1, 'New client is also authenticated';

        my $cl_btc = BOM::User::Client->new({loginid => $loginid});

        is($cl_btc->financial_assessment(), undef, 'new client has no financial assessment if previous client has none as well');

        is $client_cr->{$_}, $cl_btc->$_, "$_ is correct on created account" for keys %$client_cr;

        ok(defined($cl_btc->binary_user_id), 'BTC client has a binary user id');
        ok(defined($cl_usd->binary_user_id), 'USD client has a binary_user_id');
        is $cl_btc->binary_user_id, $cl_usd->binary_user_id, 'Both BTC and USD clients have the same binary user id';

        $params->{args}->{currency} = 'BTC';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error('cannot create another crypto currency account with same currency')
            ->error_code_is('CurrencyTypeNotAllowed', 'error code is CurrencyTypeNotAllowed');

        # Set financial assessment for default client before making a new account to check if new account inherits the financial assessment data
        my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
        $cl_usd->financial_assessment({
            data => encode_json_utf8($data),
        });
        $cl_usd->save();

        $params->{args}->{currency}       = 'LTC';
        $params->{args}->{citizen}        = 'af';
        $params->{args}->{place_of_birth} = 'af';

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
            my $password = 'jskjd8292922';
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
        $params->{token} = $auth_token;

        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;
        is $result->{error}->{code}, 'InvalidAccount', 'It should return error if client residense does not fit for maltainvest';

        $client->residence('de');
        $client->save;
        delete $params->{args}->{accept_risk};

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if client does not accept risk')
            ->error_message_is('Please provide complete details for account opening.', 'It should return error if client does not accept risk');

        $params->{args}->{residence} = 'de';

        @{$params->{args}}{keys %$client_details} = values %$client_details;
        delete $params->{args}->{first_name};

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if missing any details')
            ->error_message_is('Please provide complete details for account opening.', 'It should return error if missing any details')
            ->error_details_is({missing => ["tax_residence", "tax_identification_number", "first_name"]});
        $params->{args}->{first_name}  = $client_details->{first_name};
        $params->{args}->{residence}   = 'de';
        $params->{args}->{accept_risk} = 1;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if missing any details')
            ->error_message_is('Please provide complete details for account opening.', 'It should return error if missing any details');

        $params->{args}->{place_of_birth}            = "de";
        $params->{args}->{tax_residence}             = "de,nl";
        $params->{args}->{tax_identification_number} = "111222";

        delete $params->{args}->{citizen};

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if missing any details')
            ->error_message_is('Please provide complete details for account opening.', 'It should return error if missing any details');

        $params->{args}->{citizen} = 'at';

        $client->save;
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('email unverified', 'It should return error if email unverified')
            ->error_message_is('Your email address is unverified.', 'It should return error if email unverified');

        $user->update_email_fields(email_verified => 1);

        $params->{args}->{residence} = 'id';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('invalid residence', 'It should return error if residence does not fit with maltainvest')
            ->error_message_is(
            'Sorry, our service is not available for your country of residence.',
            'It should return error if residence does not fit with maltainvest'
            );

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

        $params->{args}->{phone} = '1234567890';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidPhone', 'It should return error if phone cannot be formatted to E.123')
            ->error_message_is('Please enter a valid phone number, including the country code (e.g. +15417541234).',
            'It should return expected error message');
        delete $params->{args}->{phone};

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Binary Investments (Europe) Ltd',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} }, 'maltainvest', 'It should return new account data');

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^MF\d+/, 'new MF loginid';

        my $token_db = BOM::Database::Model::AccessToken->new();
        my $tokens   = $token_db->get_all_tokens_by_loginid($new_loginid);
        is($tokens->[0]{info}, "App ID: $app_id", "token's app_id is correct");

        my $cl = BOM::User::Client->new({loginid => $new_loginid});
        ok($cl->status->financial_risk_approval, 'For mf accounts we will set financial risk approval status');

        is $cl->status->crs_tin_information->{reason}, 'Client confirmed tax information', "CRS status is set";

        my ($resp_loginid, $t, $uaf) =
            @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
        is $resp_loginid, $new_loginid, 'correct oauth token';

        ok $emitted{"register_details_$new_loginid"}, "register_details event emitted";
        ok $emitted{"signup_$new_loginid"},           "signup event emitted";
    };

    my $client_mlt;
    subtest 'Init MLT MF' => sub {
        lives_ok {
            my $password = 'jskjd8292922';
            my $hash_pwd = BOM::User::Password::hashpw($password);
            $email = 'new_email' . rand(999) . '@binary.com';
            $user  = BOM::User->create(
                email          => $email,
                password       => $hash_pwd,
                email_verified => 1,
            );
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email       => $email,
                residence   => 'cz',
            });
            $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code   => 'MLT',
                    email         => $email,
                    residence     => 'cz',
                    secret_answer => BOM::User::Utility::encrypt_secret_answer('mysecretanswer')});
            $auth_token = BOM::Platform::Token::API->new->create_token($client_mlt->loginid, 'test token');

            $user->add_client($client);
            $user->add_client($client_mlt);

        }
        'Initial users and clients';
    };

    subtest 'Create new account maltainvest from MLT' => sub {
        $params->{args}->{accept_risk} = 1;
        $params->{token}               = $auth_token;
        $params->{args}->{residence}   = 'gb';
        $params->{args}->{citizen}     = 'at';

        mailbox_clear();

        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_) =~ s/_// for qw/first_name last_name residence address_city/;
        $params->{args}->{phone}         = '+62 21 12345678';
        $params->{args}->{date_of_birth} = '1990-09-09';

        # We have to delete these fields here as our test helper function creates clients with different fields than what is declared above in this file. Should change this.
        delete $params->{args}->{secret_question};
        delete $params->{args}->{secret_answer};

        my $result = $rpc_ct->call_ok($method, $params)->result;
        my $new_loginid = $result->{client_id};

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
            email   => 'compliance@binary.com',
            subject => qr/\Qhas submitted the assessment test\E/
        );
        ok($msg, "Risk disclosure email received");
    };

    my $client_mx;
    subtest 'Init MX MF' => sub {
        lives_ok {
            my $password = 'jskjd8292922';
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
                residence   => 'gb',
            });
            $client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                    broker_code   => 'MX',
                    email         => $email,
                    residence     => 'gb',
                    secret_answer => BOM::User::Utility::encrypt_secret_answer('mysecretanswer')});
            $auth_token = BOM::Platform::Token::API->new->create_token($client_mx->loginid, 'test token');

            $user->add_client($client);
            $user->add_client($client_mx);
        }
        'Initial users and clients';
    };

    subtest 'Create new account maltainvest from MX' => sub {
        $params->{args}->{accept_risk} = 1;
        $params->{token}               = $auth_token;
        $params->{args}->{residence}   = 'gb';

        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_) =~ s/_// for qw/first_name last_name residence address_city/;
        $params->{args}->{phone}         = '+62 21 12345678';
        $params->{args}->{date_of_birth} = '1990-09-09';

        $client_mx->status->set('unwelcome', 'system', 'test');

        my $result = $rpc_ct->call_ok($method, $params)->result;
        is $result->{error}->{code}, 'UnwelcomeAccount', 'Client marked as unwelcome';

        $client_mx->status->clear_unwelcome;
        $result = $rpc_ct->call_ok($method, $params)->result;
        is $result->{error}->{code}, undef, 'Allow to open even if Client KYC is pending';

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

        ok $emitted{"register_details_$new_loginid"}, "register_details event emitted";
        ok $emitted{"signup_$new_loginid"},           "signup event emitted";

    };

    subtest 'Create a new account maltainvest from a virtual account' => sub {
        #create a virtual gb client
        my $password = 'jskjd8292922';
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
            residence   => 'gb',
        });
        $auth_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
        $user->add_client($client);

        $params->{args}->{accept_risk} = 1;
        $params->{token}               = $auth_token;
        $params->{args}->{residence}   = 'gb';

        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_) =~ s/_// for qw/first_name last_name residence address_city/;
        $params->{args}->{phone}         = '+62 21 12345678';
        $params->{args}->{date_of_birth} = '1990-09-09';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied',
            'Correct error code for virtual account trying to open maltainvest account without an mx account')->error_message_is('Permission denied.',
            'Correct error message for virtual account trying to open maltainvest account without an mx account');

        $client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code   => 'MX',
                email         => $email,
                residence     => 'gb',
                secret_answer => BOM::User::Utility::encrypt_secret_answer('mysecretanswer')});
        $auth_token = BOM::Platform::Token::API->new->create_token($client_mx->loginid, 'test token');
        $params->{token} = $auth_token;

        $user->add_client($client_mx);

        my $result = $rpc_ct->call_ok($method, $params)->result;
        ok $result->{client_id}, "Create an MF account after have a MX account";

        ok $emitted{'register_details_' . $result->{client_id}}, "register_details event emitted";
        ok $emitted{'signup_' . $result->{client_id}},           "signup event emitted";

        #create a virtual de client
        $email = 'virtual_de_email' . rand(999) . '@binary.com';
        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_) =~ s/_// for qw/first_name last_name residence address_city/;
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

        ok $emitted{'register_details_' . $result->{client_id}}, "register_details event emitted";
        ok $emitted{'signup_' . $result->{client_id}},           "signup event emitted";

    };
};

done_testing();
