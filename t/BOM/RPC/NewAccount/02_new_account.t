use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;

use Date::Utility;
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use POSIX qw/ ceil /;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Token;
use Client::Account;

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

    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;
    $params->{args}->{residence}    = 'id';
    $params->{args}->{utm_source}   = 'google.com';
    $params->{args}->{utm_medium}   = 'email';
    $params->{args}->{utm_campaign} = 'spring sale';
    $params->{args}->{gclid_url}    = 'FQdb3wodOkkGBgCMrlnPq42q8C';
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
        ->result_value_is(sub { shift->{currency} },     'USD', 'It should return new account data')
        ->result_value_is(sub { ceil shift->{balance} }, 10000, 'It should return new account data');

    my $new_loginid = $rpc_ct->result->{client_id};
    ok $new_loginid =~ /^VRTC\d+/, 'new VR loginid';
    my $user = BOM::Platform::User->new({email => $email});
    ok $user->utm_source =~ '^google\.com$',               'utm registered as expected';
    ok $user->gclid_url =~ '^FQdb3wodOkkGBgCMrlnPq42q8C$', 'gclid value returned as expected';
    is $user->email_consent, undef, 'email consent not passed during account creation so its undef';

    my ($resp_loginid, $t, $uaf) =
        @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
    is $resp_loginid, $new_loginid, 'correct oauth token';

    my $vr_email = 'new_email' . rand(999) . '@binary.com';
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $vr_email,
        created_for => 'account_opening'
    )->token;
    $params->{args}->{email_consent} = 1;

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
        ->result_value_is(sub { shift->{currency} },     'USD', 'It should return new account data')
        ->result_value_is(sub { ceil shift->{balance} }, 10000, 'It should return new account data');

    $user = BOM::Platform::User->new({email => $vr_email});
    is $user->email_consent, 1, 'email consent is correct';
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
            my $hash_pwd = BOM::Platform::Password::hashpw($password);
            $email = 'new_email' . rand(999) . '@binary.com';
            $user  = BOM::Platform::User->create(
                email    => $email,
                password => $hash_pwd
            );
            $user->save;

            $vclient = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email       => $email,
            });

            $user->add_loginid({loginid => $vclient->loginid});
            $user->save;
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
            my $module = Test::MockModule->new('Client::Account');
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

        $user->email_verified(1);
        $user->save;
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
    };

};

$method = 'new_account_maltainvest';
$params = {
    language => 'EN',
    source   => 1,
    country  => 'ru',
    args     => {},
};

subtest $method => sub {
    my ($user, $client, $auth_token);

    subtest 'Initialization' => sub {
        lives_ok {
            my $password = 'jskjd8292922';
            my $hash_pwd = BOM::Platform::Password::hashpw($password);
            $email = 'new_email' . rand(999) . '@binary.com';
            $user  = BOM::Platform::User->create(
                email    => $email,
                password => $hash_pwd
            );
            $user->save;
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email       => $email,
            });
            $auth_token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token');

            $user->add_loginid({loginid => $client->loginid});
            $user->save;
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
            my $module = Test::MockModule->new('Client::Account');
            $module->mock('new', sub { });

            $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('AuthorizationRequired', 'It should check auth');
        }
    };

    subtest 'Create new account maltainvest' => sub {
        $params->{args}->{accept_risk} = 1;
        $params->{token} = $auth_token;

        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;
        is $result->{error}->{code}, 'InsufficientAccountDetails', 'It should return error if client residense does not fit for maltainvest';

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

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('email unverified', 'It should return error if email unverified')
            ->error_message_is('Your email address is unverified.', 'It should return error if email unverified');

        $user->email_verified(1);
        $user->save;

        $params->{args}->{residence} = 'id';

        warnings_like {
            $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('invalid residence',
                'It should return error if residence does not fit with maltainvest')->error_message_is(
                'Sorry, our service is not available for your country of residence.',
                'It should return error if residence does not fit with maltainvest'
                );
        }
        [qr/^acc opening err:/], "Expected warn about wrong residence";

        $params->{args}->{residence} = 'de';

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Binary Investments (Europe) Ltd',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} }, 'maltainvest', 'It should return new account data');

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^MF\d+/, 'new MF loginid';

        my $cl = Client::Account->new({loginid => $new_loginid});
        ok($cl->get_status('financial_risk_approval'), 'For mf accounts we will set financial risk approval status');

        is $cl->get_status('crs_tin_information')->reason, Date::Utility->new()->date, "CRS date is set for account opening date";

        my ($resp_loginid, $t, $uaf) =
            @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
        is $resp_loginid, $new_loginid, 'correct oauth token';
    };

    my $client_mlt;
    subtest 'Init MLT MF' => sub {
        lives_ok {
            my $password = 'jskjd8292922';
            my $hash_pwd = BOM::Platform::Password::hashpw($password);
            $email = 'new_email' . rand(999) . '@binary.com';
            $user  = BOM::Platform::User->create(
                email    => $email,
                password => $hash_pwd
            );
            $user->save;
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

            $user->add_loginid({loginid => $client->loginid});
            $user->add_loginid({loginid => $client_mlt->loginid});
            $user->email_verified(1);
            $user->save;
        }
        'Initial users and clients';
    };

    subtest 'Create new account maltainvest from MLT' => sub {
        $params->{args}->{accept_risk} = 1;
        $params->{token}               = $auth_token;
        $params->{args}->{residence}   = 'cz';

        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_) =~ s/_// for qw/first_name last_name residence address_city/;
        $params->{args}->{phone}         = '1234567890';
        $params->{args}->{date_of_birth} = '1990-09-09';

        my $result        = $rpc_ct->call_ok($method, $params)->result;
        my $new_loginid   = $result->{client_id};
        my $auth_token_mf = BOM::Database::Model::AccessToken->new->create_token($new_loginid, 'test token');

        # make sure data is same, as in first account, regardless of what we have provided
        my $cl = Client::Account->new({loginid => $new_loginid});
        is $client_mlt->$_, $cl->$_, "$_ is correct on created account" for qw/first_name last_name residence address_city phone date_of_birth/;

        $result = $rpc_ct->call_ok('get_settings', {token => $auth_token_mf})->result;
        is($result->{tax_residence}, 'de,nl', 'MF client has tax residence set');
        $result = $rpc_ct->call_ok('get_financial_assessment', {token => $auth_token_mf})->result;
        isnt(keys $result, 0, 'MF client has financial assessment set');
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
            my $hash_pwd = BOM::Platform::Password::hashpw($password);
            $email = 'new_email' . rand(999) . '@binary.com';
            $user  = BOM::Platform::User->create(
                email    => $email,
                password => $hash_pwd
            );
            $user->save;
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTJ',
                email       => $email,
            });
            $auth_token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token');

            $user->add_loginid({loginid => $client->loginid});
            $user->save;

            $email       = 'new_email' . rand(999) . '@binary.com';
            $normal_user = BOM::Platform::User->create(
                email    => $email,
                password => $hash_pwd
            );
            $normal_user->save;
            $normal_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email       => $email,
            });
            $normal_auth_token = BOM::Database::Model::AccessToken->new->create_token($normal_vr->loginid, 'test token');

            $normal_user->add_loginid({loginid => $normal_vr->loginid});
            $normal_user->save;
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
            my $module = Test::MockModule->new('Client::Account');
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

        $user->email_verified(1);
        $user->save;

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
