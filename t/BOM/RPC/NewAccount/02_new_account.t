use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;

use Date::Utility;
use MojoX::JSON::RPC::Client;
use POSIX qw/ ceil /;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Token;
use BOM::User::Client;
use Email::Stuffer::TestLinks;
use Email::Folder::Search;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use BOM::Test::Helper::FinancialAssessment;

use utf8;

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
};

$params = {
    language => 'EN',
    source   => 1,
    country  => 'ru',
    args     => {},
};

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

$method = 'new_account_virtual';
subtest $method => sub {
    $params->{args}->{client_password}   = '123';
    $params->{args}->{verification_code} = 'wrong token';

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('PasswordError', 'If password is weak it should return error')
        ->error_message_is('Password should be at least six characters, including lower and uppercase letters with numbers.',
        'If password is weak it should return error_message');

    $params->{args}->{client_password} = 'verylongandhardpasswordDDD1!';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code is wrong it should return error')
        ->error_message_is('Your token has expired or is invalid.', 'If email verification_code is wrong it should return error_message');

    $params->{args}->{residence}    = 'id';
    $params->{args}->{utm_source}   = 'google.com';
    $params->{args}->{utm_medium}   = 'email';
    $params->{args}->{utm_campaign} = 'spring sale';
    $params->{args}->{gclid_url}    = 'FQdb3wodOkkGBgCMrlnPq42q8C';

    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
        ->result_value_is(sub { shift->{currency} },     'USD', 'It should return new account data')
        ->result_value_is(sub { ceil shift->{balance} }, 10000, 'It should return new account data');

    my $new_loginid = $rpc_ct->result->{client_id};
    ok $new_loginid =~ /^VRTC\d+/, 'new VR loginid';
    my $user = BOM::User->new(
        email => $email,
    );

    ok $user->{utm_source} =~ '^google\.com$',               'utm registered as expected';
    ok $user->{gclid_url} =~ '^FQdb3wodOkkGBgCMrlnPq42q8C$', 'gclid value returned as expected';
    is $user->{email_consent}, 1, 'email consent for new account is 1 for residence under costarica';

    my ($resp_loginid, $t, $uaf) =
        @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
    is $resp_loginid, $new_loginid, 'correct oauth token';

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

        $user = BOM::User->new(
            email => $vr_email,
        );
        is $user->{email_consent}, 0, 'email consent for new account is 0 for european clients - gb';
    };
};

$method = 'new_account_real';
$params = {
    language => 'EN',
    source   => 1,
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
            $auth_token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token');

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
        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;
        isnt $result->{error}->{code}, 'InvalidAccount', 'No error with duplicate details but residence not provided so it errors out';

        $params->{token} = BOM::Database::Model::AccessToken->new->create_token($vclient->loginid, 'test token');
        $params->{args}->{residence} = 'id';

        @{$params->{args}}{keys %$client_details} = values %$client_details;
        delete $params->{args}->{first_name};

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if missing any details')
            ->error_message_is('Please provide complete details for account opening.', 'It should return error if missing any details');

        $params->{args}->{first_name} = $client_details->{first_name};
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('email unverified', 'It should return error if email unverified')
            ->error_message_is('Your email address is unverified.', 'It should return error if email unverified');

        $user->update_email_fields(email_verified => 1);

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Binary (C.R.) S.A.',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} }, 'costarica', 'It should return new account data');

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^CR\d+$/, 'new CR loginid';

        my ($resp_loginid, $t, $uaf) =
            @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
        is $resp_loginid, $new_loginid, 'correct oauth token';

        my $new_client = BOM::User::Client->new({loginid => $new_loginid});
        $new_client->status->set('duplicate_account', 'system', 'reason');

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Binary (C.R.) S.A.',
            'It should return new account data'
            )->result_value_is(sub { shift->{landing_company_shortcode} },
            'costarica', 'It should return new account data if one of the account is marked as duplicate');
        $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^CR\d+$/, 'new CR loginid';
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
        $params->{args} = {'currency' => 'BCH'};
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('create crypto currency account, reusing info')
            ->result_value_is(sub { shift->{currency} }, 'BCH', 'crypto account currency is BCH');

        sleep 2;

        my $loginid = $rpc_ct->result->{client_id};

        $rpc_ct->call_ok('get_account_status', {token => $params->{token}});

        my $is_authenticated = grep { $_ eq 'authenticated' } @{$rpc_ct->result->{status}};

        is $is_authenticated, 1, 'New client is also authenticated';

        my $cl_bch = BOM::User::Client->new({loginid => $loginid});

        is($cl_bch->financial_assessment(), undef, 'new client has no financial assessment if previous client has none as well');

        is $client_cr->{$_}, $cl_bch->$_, "$_ is correct on created account" for keys %$client_cr;

        ok(defined($cl_bch->binary_user_id), 'BCH client has a binary user id');
        ok(defined($cl_usd->binary_user_id), 'USD client has a binary_user_id');
        is $cl_bch->binary_user_id, $cl_usd->binary_user_id, 'Both BCH and USD clients have the same binary user id';

        $params->{args}->{currency} = 'BCH';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error('cannot create another crypto currency account with same currency')
            ->error_code_is('CurrencyTypeNotAllowed', 'error code is CurrencyTypeNotAllowed');

        # Set financial assessment for default client before making a new account to check if new account inherits the financial assessment data
        my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
        $cl_usd->financial_assessment({
            data => encode_json_utf8($data),
        });
        $cl_usd->save();

        $params->{args}->{currency} = 'LTC';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('create second crypto currency account')
            ->result_value_is(sub { shift->{currency} }, 'LTC', 'crypto account currency is LTC');

        my $cl_ltc = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});

        cmp_deeply(
            decode_json_utf8($cl_ltc->financial_assessment->{data}),
            decode_json_utf8($cl_usd->financial_assessment->{data}),
            "new client financial assessment is the same as old client financial_assessment"
        );
    };
};

$method = 'new_account_maltainvest';
$params = {
    language => 'EN',
    source   => 1,
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
                citizen => '',
            });
            $auth_token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token');

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
            ->error_message_is('Please provide complete details for account opening.', 'It should return error if missing any details');

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

        $client->citizen('at');
        $client->save;
        $params->{args}->{citizen} = $client_details->{citizen};

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

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Binary Investments (Europe) Ltd',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} }, 'maltainvest', 'It should return new account data');

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^MF\d+/, 'new MF loginid';

        my $cl = BOM::User::Client->new({loginid => $new_loginid});
        ok($cl->status->get('financial_risk_approval'), 'For mf accounts we will set financial risk approval status');

        is $cl->status->get('crs_tin_information')->{reason}, 'Client confirmed tax information', "CRS status is set";

        my ($resp_loginid, $t, $uaf) =
            @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
        is $resp_loginid, $new_loginid, 'correct oauth token';
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
                broker_code => 'MLT',
                email       => $email,
                residence   => 'cz',
            });
            $auth_token = BOM::Database::Model::AccessToken->new->create_token($client_mlt->loginid, 'test token');

            $user->add_client($client);
            $user->add_client($client_mlt);
        }
        'Initial users and clients';
    };

    subtest 'Create new account maltainvest from MLT' => sub {
        $params->{args}->{accept_risk} = 1;
        $params->{token}               = $auth_token;
        $params->{args}->{residence}   = 'gb';

        my $mailbox = Email::Folder::Search->new('/tmp/default.mailbox');
        $mailbox->init();
        $mailbox->clear();

        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_) =~ s/_// for qw/first_name last_name residence address_city/;
        $params->{args}->{phone}         = '1234567890';
        $params->{args}->{date_of_birth} = '1990-09-09';

        my $result        = $rpc_ct->call_ok($method, $params)->result;
        my $new_loginid   = $result->{client_id};
        my $auth_token_mf = BOM::Database::Model::AccessToken->new->create_token($new_loginid, 'test token');

        # make sure data is same, as in first account, regardless of what we have provided
        my $cl = BOM::User::Client->new({loginid => $new_loginid});
        is $client_mlt->$_, $cl->$_, "$_ is correct on created account" for qw/first_name last_name residence address_city phone date_of_birth/;

        $result = $rpc_ct->call_ok('get_settings', {token => $auth_token_mf})->result;
        is($result->{tax_residence}, 'de,nl', 'MF client has tax residence set');
        $result = $rpc_ct->call_ok('get_financial_assessment', {token => $auth_token_mf})->result;
        isnt(keys %$result, 0, 'MF client has financial assessment set');
        my @msgs = $mailbox->search(
            email   => 'compliance@binary.com',
            subject => qr/\Qhas submitted the assessment test\E/
        );
        ok(@msgs, "Risk disclosure email received");
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
                broker_code => 'MX',
                email       => $email,
                residence   => 'gb',
            });
            $auth_token = BOM::Database::Model::AccessToken->new->create_token($client_mx->loginid, 'test token');

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
        $params->{args}->{phone}         = '1234567890';
        $params->{args}->{date_of_birth} = '1990-09-09';

        $client_mx->status->set('unwelcome', 'system', 'test');

        my $result = $rpc_ct->call_ok($method, $params)->result;
        is $result->{error}->{code}, 'UnwelcomeAccount', 'Client marked as unwelcome';

        $client_mx->status->clear('unwelcome');

        $result = $rpc_ct->call_ok($method, $params)->result;
        is $result->{error}->{code}, undef, 'Allow to open even if Client KYC is pending';

        my $new_loginid = $result->{client_id};
        my $auth_token_mf = BOM::Database::Model::AccessToken->new->create_token($new_loginid, 'test token');

        # make sure data is same, as in first account, regardless of what we have provided
        my $cl = BOM::User::Client->new({loginid => $new_loginid});
        is $client_mx->$_, $cl->$_, "$_ is correct on created account" for qw/first_name last_name residence address_city phone date_of_birth/;

        $result = $rpc_ct->call_ok('get_settings', {token => $auth_token_mf})->result;
        is($result->{tax_residence}, 'de,nl', 'MF client has tax residence set');
        $result = $rpc_ct->call_ok('get_financial_assessment', {token => $auth_token_mf})->result;
        isnt(keys %$result, 0, 'MF client has financial assessment set');
    };
};

$method = 'new_account_japan';
$params = {
    language => 'EN',
    source   => 1,
    country  => 'ru',
    args     => {},
};

subtest $method => sub {
    my ($user, $client, $auth_token, $normal_vr, $normal_user, $normal_auth_token, $normal_params);

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
                broker_code => 'VRTJ',
                email       => $email,
            });
            $auth_token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token');

            $user->add_client($client);

            $email       = 'new_email' . rand(999) . '@binary.com';
            $normal_user = BOM::User->create(
                email    => $email,
                password => $hash_pwd
            );
            $normal_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email       => $email,
            });
            $normal_auth_token = BOM::Database::Model::AccessToken->new->create_token($normal_vr->loginid, 'test token');

            $normal_user->add_client($normal_vr);
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

    subtest 'Create new account japan' => sub {
        $normal_params = $params;
        $normal_params->{token} = $normal_auth_token;

        my $result = $rpc_ct->call_ok($method, $normal_params)->has_no_system_error->has_error->result;
        is $result->{error}->{code}, 'PermissionDenied',
            'It should return an error if normal virtual client tried to make japan real account call, only japan-virtual is allowed';

        $params->{token} = $auth_token;

        $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;
        is $result->{error}->{code}, 'InvalidAccount', 'It should return error if client residense does not fit for japan';

        $client->residence('jp');
        $client->save;

        $params->{args}->{residence} = 'jp';
        @{$params->{args}}{keys %$client_details} = values %$client_details;
        delete $params->{args}->{first_name};

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if missing any details')
            ->error_message_is('Please provide complete details for account opening.', 'It should return error if missing any details');

        $params->{args}->{first_name} = $client_details->{first_name};
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('email unverified', 'It should return error if email unverified')
            ->error_message_is('Your email address is unverified.', 'It should return error if email unverified');

        $user->update_email_fields(email_verified => 1);

        $params->{args}->{annual_income}                  = '1-3 million JPY';
        $params->{args}->{financial_asset}                = '1-3 million JPY';
        $params->{args}->{trading_experience_public_bond} = 'Less than 6 months';
        $params->{args}->{trading_experience_margin_fx}   = '6 months to 1 year';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('insufficient score', 'It should return error if client has insufficient score')
            ->error_message_is(
            'Unfortunately your answers to the questions above indicate that you do not have sufficient financial resources or trading experience to be eligible to open a trading account at this time.',
            'It should return error if client has insufficient score'
            );

        $params->{args}->{annual_income}                  = '50-100 million JPY';
        $params->{args}->{trading_experience_public_bond} = 'Over 5 years';
        $params->{args}->{trading_experience_margin_fx}   = 'Over 5 years';

        $params->{args}->{agree_use_electronic_doc}             = 1;
        $params->{args}->{agree_warnings_and_policies}          = 1;
        $params->{args}->{confirm_understand_own_judgment}      = 1;
        $params->{args}->{confirm_understand_trading_mechanism} = 1;
        $params->{args}->{confirm_understand_total_loss}        = 1;
        $params->{args}->{confirm_understand_judgment_time}     = 1;
        $params->{args}->{confirm_understand_sellback_loss}     = 1;
        $params->{args}->{confirm_understand_shortsell_loss}    = 1;
        $params->{args}->{confirm_understand_company_profit}    = 1;
        $params->{args}->{confirm_understand_expert_knowledge}  = 1;
        $params->{args}->{declare_not_fatca}                    = 1;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_no_error->result_value_is(sub { shift->{landing_company} }, 'Binary KK', 'It should return new account data')
            ->result_value_is(sub { shift->{landing_company_shortcode} }, 'japan', 'It should return new account data');

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^JP\d+/, 'new JP loginid';

        my ($resp_loginid, $t, $uaf) =
            @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
        is $resp_loginid, $new_loginid, 'correct oauth token';
    };
};

done_testing();
