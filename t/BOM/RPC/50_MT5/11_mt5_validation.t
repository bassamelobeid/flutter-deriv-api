use strict;
use warnings;
use feature 'state';

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Locale::Country::Extra;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(create_client);
use BOM::User;
use BOM::Database::Model::OAuth;
use BOM::User::Password;
use Email::Stuffer::TestLinks;
use BOM::Config::Runtime;

# disable routing to demo p01_ts02
my $p01_ts02_load = BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02;
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02(0);

# disable routing to demo p01_ts03
my $p01_ts03_load = BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03;
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03(0);

my %financial_data = (
    "forex_trading_experience"             => "Over 3 years",
    "forex_trading_frequency"              => "0-5 transactions in the past 12 months",
    "binary_options_trading_experience"    => "1-2 years",
    "binary_options_trading_frequency"     => "40 transactions or more in the past 12 months",
    "cfd_trading_experience"               => "1-2 years",
    "cfd_trading_frequency"                => "0-5 transactions in the past 12 months",
    "other_instruments_trading_experience" => "Over 3 years",
    "other_instruments_trading_frequency"  => "6-10 transactions in the past 12 months",
    "employment_industry"                  => "Finance",
    "education_level"                      => "Secondary",
    "income_source"                        => "Self-Employed",
    "net_income"                           => '$25,000 - $50,000',
    "estimated_worth"                      => '$100,000 - $250,000',
    "account_turnover"                     => '$25,000 - $50,000',
    "occupation"                           => 'Managers',
    "employment_status"                    => "Self-Employed",
    "source_of_wealth"                     => "Company Ownership",
);

my $assessment_keys = {
    financial_info => [
        qw/
            occupation
            education_level
            source_of_wealth
            estimated_worth
            account_turnover
            employment_industry
            income_source
            net_income
            employment_status/
    ],
    trading_experience => [
        qw/
            other_instruments_trading_frequency
            other_instruments_trading_experience
            binary_options_trading_frequency
            binary_options_trading_experience
            forex_trading_frequency
            forex_trading_experience
            cfd_trading_frequency
            cfd_trading_experience/
    ],
};

my %financial_data_mf = (
    "risk_tolerance"                           => "Yes",
    "source_of_experience"                     => "I have an academic degree, professional certification, and/or work experience.",
    "cfd_experience"                           => "Less than a year",
    "cfd_frequency"                            => "1 - 5 transactions in the past 12 months",
    "trading_experience_financial_instruments" => "Less than a year",
    "trading_frequency_financial_instruments"  => "1 - 5 transactions in the past 12 months",
    "cfd_trading_definition"                   => "Speculate on the price movement.",
    "leverage_impact_trading"                  => "Leverage lets you open larger positions for a fraction of the trade's value.",
    "leverage_trading_high_risk_stop_loss"     => "Close your trade automatically when the loss is more than or equal to a specific amount.",
    "required_initial_margin"                  => "When opening a Leveraged CFD trade.",
    "employment_industry"                      => "Finance",
    "education_level"                          => "Secondary",
    "income_source"                            => "Self-Employed",
    "net_income"                               => '$25,000 - $50,000',
    "estimated_worth"                          => '$100,000 - $250,000',
    "account_turnover"                         => '$25,000 - $50,000',
    "occupation"                               => 'Managers',
    "employment_status"                        => "Self-Employed",
    "source_of_wealth"                         => "Company Ownership",
);

my $assessment_keys_mf = {
    financial_info => [
        qw/
            occupation
            education_level
            source_of_wealth
            estimated_worth
            account_turnover
            employment_industry
            income_source
            net_income
            employment_status/
    ],
    trading_experience => [
        qw/
            risk_tolerance
            source_of_experience
            cfd_experience
            cfd_frequency
            trading_experience_financial_instruments
            trading_frequency_financial_instruments
            cfd_trading_definition
            leverage_impact_trading
            leverage_trading_high_risk_stop_loss
            required_initial_margin/
    ],
};

my @emit_args;
my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_emitter->mock(
    'emit' => sub {
        @emit_args = @_;
    });

#mocking this module will let us avoid making calls to MT5 server.
my $mt5_account_info;
my $mocked_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
$mocked_mt5->mock(
    'create_user' => sub {
        state $count = 1000;
        $mt5_account_info = {shift->%*};
        return Future->done({login => 'MTD' . $count++});
    },
    'deposit' => sub {
        return Future->done({status => 1});
    },
    'get_group' => sub {
        return Future->done({
            'group'    => $mt5_account_info->{group} // 'demo\p01_ts01\synthetic\svg_std_usd',
            'currency' => 'USD',
            'leverage' => 500
        });
    },
    'get_user' => sub {
        my $country_name = $mt5_account_info->{country} ? Locale::Country::Extra->new()->country_from_code($mt5_account_info->{country}) : '';
        return Future->done({%$mt5_account_info, country => $country_name // $mt5_account_info->{country}});
    },
);

my $mocked_user = Test::MockModule->new('BOM::User');
$mocked_user->mock(
    'update_loginid_status' => sub {
        return 1;
    });

my $mock_auth_docs = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
my $documents_expired;

$mock_auth_docs->mock(
    'expired',
    sub {
        return $documents_expired // $mock_auth_docs->original('expired')->(@_);
    });

my $c = BOM::Test::RPC::QueueClient->new();

subtest 'new account' => sub {
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        email          => 'test1@binary.com',
        broker_code    => 'CR',
        citizen        => 'at',
        place_of_birth => 'at',
    });
    $test_client->set_default_account('USD');
    $test_client->save();

    my $password = 'UserPassAbcd33@!';
    my $hash_pwd = BOM::User::Password::hashpw($password);
    my $user     = BOM::User->create(
        email    => 'test.account@binary.com',
        password => $hash_pwd,
    );
    $user->update_trading_password('Abcd33@!');
    $user->add_client($test_client);

    my $m     = BOM::Platform::Token::API->new;
    my $token = $m->create_token($test_client->loginid, 'test token');

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => 12345,
        args     => {
            mainPassword   => 'Abcd33@!',
            investPassword => 'Abcd12656@!',
        },
    };
    $c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'check invalid token');

    $params->{token} = $token;

    $params->{args}->{account_type} = undef;
    $c->call_ok($method, $params)->has_error->error_code_is('InvalidAccountType', 'Correct error message for undef account type');
    $params->{args}->{account_type} = 'dummy';
    $c->call_ok($method, $params)->has_error->error_code_is('InvalidAccountType', 'Correct error message for invalid account type');
    $params->{args}->{account_type} = 'demo';

    my $citizen = $test_client->citizen;

    $test_client->citizen('');
    $test_client->save;

    $c->call_ok($method, $params)->has_no_error('Citizenship is not required for creating demo accounts');

    $params->{args}->{account_type} = 'gaming';
    $c->call_ok($method, $params)->has_no_error('Citizenship is not required for creating gaming accounts');

    $params->{args}->{account_type}     = 'financial';
    $params->{args}->{mt5_account_type} = 'financial';

    $c->call_ok($method, $params)->has_no_error('Citizenship is not required for creating financial accounts');

    $params->{args}->{mt5_account_type} = 'financial_stp';

    my $result = $c->call_ok($method, $params)->response->result;
    is $result->{error}->{code}, 'ASK_FIX_DETAILS', 'Correct error code if citizen is missing for financial_stp account';
    is $result->{error}->{message_to_client}, 'Your profile appears to be incomplete. Please update your personal details to continue.',
        'Correct error message if citizen is missing for financial_stp account';
    cmp_bag($result->{error}{details}{missing}, ['citizen', 'account_opening_reason'], 'Missing citizen should be under details.');

    $params->{args}->{account_type} = 'gaming';

    $test_client->account_opening_reason('speculatove');
    $test_client->citizen($citizen);
    $test_client->save;

    $params->{args}->{account_type}   = 'demo';
    $params->{args}->{mainPassword}   = 'Abcd33@!';
    $params->{args}->{investPassword} = 'Abcd33@!';
    $c->call_ok($method, $params)->has_error->error_message_is('Please use different passwords for your investor and main accounts.',
        'Correct error message for same password');

    $params->{args}->{mainPassword} = 'Test1@binary.com';
    $c->call_ok($method, $params)->has_error->error_code_is('MT5PasswordEmailLikenessError')
        ->error_message_is('You cannot use your email address as your password.', 'Correct error message for using email as mainPassword');

    $params->{args}->{mainPassword} = '123sdadasd';
    $c->call_ok($method, $params)->has_error->error_code_is('IncorrectMT5PasswordFormat')
        ->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'Correct error message for using weak mainPassword');
    $params->{args}->{mainPassword} = 'Abcd33@!';

    $params->{args}->{investPassword}   = 'Abcd31231233@!';
    $params->{args}->{mt5_account_type} = 'dummy';
    $c->call_ok($method, $params)->has_error->error_code_is('InvalidSubAccountType', 'Invalid sub account type error message');

    $params->{args}->{account_type} = 'financial';

    my $pob = $test_client->place_of_birth;

    delete $params->{args}->{mt5_account_type};
    $c->call_ok($method, $params)->has_error->error_code_is('InvalidSubAccountType', 'Sub account mandatory for financial');

    $params->{args}->{mt5_account_type} = 'financial_stp';
    $test_client->aml_risk_classification('high');
    $test_client->save();
    $c->call_ok($method, $params)
        ->has_error->error_message_is('Please complete your financial assessment.', 'Financial assessment mandatory for financial account');

    # Non-MLT/CR client
    $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
        citizen     => 'de',
        residence   => 'fr',
    });
    $test_client->set_default_account('EUR');
    $test_client->account_opening_reason("test");
    $test_client->save();

    $user->add_client($test_client);

    $m               = BOM::Platform::Token::API->new;
    $token           = $m->create_token($test_client->loginid, 'test token 2');
    $params->{token} = $token;

    $c->call_ok($method, $params)->has_error->error_code_is('MT5NotAllowed', 'Only svg, malta, maltainvest and champion fx clients allowed.');

    SKIP: {
        skip "Unable to Retrieve files from PHP MT5 Server Yet";

        # testing unicode name
        $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $test_client->email('test.account@binary.com');
        $test_client->save;
        my $user = BOM::User->create(
            email    => 'test.account@binary.com',
            password => 'Abcd33@!',
        );
        $user->add_client($test_client);

        $c     = BOM::Test::RPC::QueueClient->new();
        $m     = BOM::Platform::Token::API->new;
        $token = $m->create_token($test_client->loginid, 'test token');

        # set the params
        $params->{token}                  = $token;
        $params->{args}->{account_type}   = 'demo';
        $params->{args}->{country}        = 'mt';
        $params->{args}->{email}          = 'test.account@binary.com';
        $params->{args}->{name}           = 'J\x{c3}\x{b2}s\x{c3}\x{a9}';
        $params->{args}->{investPassword} = 'Abcd33@!';
        $params->{args}->{mainPassword}   = 'Abcd82378@!';
        $params->{args}->{leverage}       = 100;

        $c->call_ok($method, $params)->has_no_error();
        like($c->response->{rpc_response}->{result}->{login}, qr/[0-9]+/, 'Should return MT5 ID');
    }
};

subtest 'CR account types - low risk' => sub {
    my $client = create_client('CR');
    $client->set_default_account('USD');
    $client->place_of_birth('ai');
    $client->residence('ai');
    $client->aml_risk_classification('low');
    $client->save();

    my $user = BOM::User->create(
        email    => 'cr+low@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo account
    my $login = create_mt5_account->(
        $c, $token, $client,
        {
            country      => 'mt',
            account_type => 'demo'
        });
    ok($login, 'demo account successfully created for a low risk client');
    is $mt5_account_info->{country}, 'Anguilla',                            'requested country was masked by client_s country of residence';
    is $mt5_account_info->{group},   'demo\p01_ts01\synthetic\svg_std_usd', 'correct CR demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        });
    is $mt5_account_info->{group}, 'demo\p01_ts01\financial\svg_std_usd', 'correct CR financial demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        });
    is $mt5_account_info->{group}, 'demo\p01_ts01\financial\labuan_stp_usd', 'correct CR financial_stp demo group';

    #real accounts
    financial_assessment($client, 'none');
    $login = create_mt5_account->($c, $token, $client, {account_type => 'gaming'});
    like $mt5_account_info->{group}, qr/real\\p01_ts04\\synthetic\\svg_std_usd\\\d{2}/, 'correct CR gaming group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        });
    ok $login, 'financial mt5 account is created without authentication and FA';
    is $mt5_account_info->{group}, 'real\p01_ts01\financial\svg_std_usd', 'correct CR financial group';

    my $error = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        },
        'ASK_FIX_DETAILS',
        'Required fields missing for financial_stp financial account'
    );
    cmp_bag($error->{details}{missing}, ['account_opening_reason'], 'Missing account_opening_reason should appear in details.');
    $client->account_opening_reason('Speculative');
    $client->save();

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        },
    );
    authenticate($client);

    $documents_expired = 1;
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        },
        'ExpiredDocumentsMT5',
        'valid documents are required for financial_stp mt5 accounts'
    );
    $documents_expired = 0;

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        });
    ok $login, 'financial_stp account created without financial assessment';
    is $mt5_account_info->{group}, 'real\p01_ts01\financial\labuan_stp_usd', 'correct CR financial_stp group';
};

subtest 'CR account types - high risk' => sub {
    my $user = BOM::User->create(
        email    => 'cr+high@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');
    my $client = create_client('CR');
    $client->set_default_account('USD');
    $client->place_of_birth('ai');
    $client->residence('ai');
    $client->aml_risk_classification('high');
    $client->save();
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo account
    my $login = create_mt5_account->(
        $c, $token, $client,
        {
            country      => 'mt',
            account_type => 'demo'
        });
    ok($login, 'demo account successfully created for a high risk client');
    is $mt5_account_info->{group}, 'demo\p01_ts01\synthetic\svg_std_usd', 'correct CR demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        });
    is $mt5_account_info->{group}, 'demo\p01_ts01\financial\svg_std_usd', 'correct CR financial demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        },
    );
    is $mt5_account_info->{group}, 'demo\p01_ts01\financial\labuan_stp_usd', 'correct CR financial stp demo group';
    #real accounts

    financial_assessment($client, 'none');
    create_mt5_account->(
        $c, $token, $client, {account_type => 'gaming'},
        'FinancialAssessmentRequired', 'Financial assessment is required for high risk clients'
    );

    financial_assessment($client, 'financial_info');
    $login = create_mt5_account->($c, $token, $client, {account_type => 'gaming'});
    ok $login, 'gaming account created with finantial information alone';
    like $mt5_account_info->{group}, qr/real\\p01_ts04\\synthetic\\svg_std_usd\\\d{2}/, 'correct CR gaming group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        });
    ok $login, 'financial mt5 account is created without authentication';
    is $mt5_account_info->{group}, 'real\p01_ts01\financial\svg_std_usd', 'correct CR financial group';
};

subtest 'MLT account types - low risk' => sub {
    my $client = create_client('MLT');
    $client->set_default_account('EUR');
    $client->residence('at');
    $client->aml_risk_classification('low');
    $client->account_opening_reason('speculative');
    $client->save();

    my $user = BOM::User->create(
        email    => 'mlt+low@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo account
    create_mt5_account->($c, $token, $client, {account_type => 'demo'}, 'MT5NotAllowed', 'MLT client cannot gaming demo account');

    my $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        });
    ok $login, 'MLT client can create a financial demo account';
    is $mt5_account_info->{group}, 'demo\p01_ts01\financial\maltainvest_std_eur', 'correct MLT demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'MLT client cannot create a financial_stp demo account'
    );

    #real accounts
    create_mt5_account->($c, $token, $client, {account_type => 'gaming'}, 'MT5NotAllowed', 'MLT client cannot gaming demo account');

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'FinancialAccountMissing',
        'MLT client cannot create a financial real account before upgrading to MF'
    );

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'MLT client cannot create a financial_stp real account'
    );
};

subtest 'MLT account types - high risk' => sub {
    my $client = create_client('MLT');
    $client->set_default_account('EUR');
    $client->residence('at');
    $client->aml_risk_classification('high');
    $client->account_opening_reason('speculative');
    $client->save();

    my $user = BOM::User->create(
        email    => 'mlt+high@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo account
    create_mt5_account->($c, $token, $client, {account_type => 'demo'}, 'MT5NotAllowed', 'MLT client cannot create a gaming demo account');

    my $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        });
    ok $login, 'MLT client can create a financial demo account';
    is $mt5_account_info->{group}, 'demo\p01_ts01\financial\maltainvest_std_eur', 'correct MLT demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'MLT client cannot create a financial_stp demo account'
    );

    #real accounts
    financial_assessment($client, 'none');
    create_mt5_account->($c, $token, $client, {account_type => 'gaming'}, 'MT5NotAllowed', 'Gaming account not allowed');

    financial_assessment($client, 'financial_info');
    create_mt5_account->($c, $token, $client, {account_type => 'gaming'}, 'MT5NotAllowed', 'Gaming account not allowed');

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'FinancialAccountMissing',
        'MLT client cannot create a financial real account before upgrading to MF'
    );

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'MLT client cannot create a financial_stp real account'
    );
};

subtest 'MF accout types' => sub {
    my $client = create_client('MF');
    $client->set_default_account('EUR');
    $client->residence('at');
    $client->tax_residence('at');
    $client->tax_identification_number('1234');
    $client->account_opening_reason('speculative');
    $client->aml_risk_classification('low');
    $client->save();

    my $user = BOM::User->create(
        email    => 'mf+low@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo accounts
    create_mt5_account->($c, $token, $client, {account_type => 'demo'}, 'MT5NotAllowed', 'Demo gaming account not allowed');

    my $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        });
    ok($login, 'demo financial account successfully created for an MF client');
    is $mt5_account_info->{group}, 'demo\p01_ts01\financial\maltainvest_std_eur', 'correct MF demo group';

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'non-professional MF clients cannot create demo financial_stp account'
    );

    $client->status->set("professional");
    $client->save;
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'professional MF clients cannot create demo financial_stp accounts either'
    );
    $client->status->clear_professional;
    $client->save;

    #real accounts
    financial_assessment($client, 'none');
    create_mt5_account->($c, $token, $client, {account_type => 'gaming'}, 'MT5NotAllowed', 'MF client cannot create gaming account');

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'FinancialAssessmentRequired',
        'Financial assessment is required for MF clients'
    );

    financial_assessment($client, 'financial_info');
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'FinancialAssessmentRequired',
        'Financial info is not enough for MF clients'
    );

    $client->aml_risk_classification('standard');
    financial_assessment($client, 'trading_experience');
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'FinancialAssessmentRequired',
        'Trading experience is not enough for MF clients for standard or high risk clients'
    );

    $client->aml_risk_classification('low');
    financial_assessment($client, 'full');
    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        });
    ok($login, 'real financial account successfully created for an MF client');
    is $mt5_account_info->{group}, 'real\p01_ts01\financial\maltainvest_std-hr_eur', 'correct MF financial group';

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'MF client cannot create a real financial_stp account'
    );

    $client->status->set("professional");
    $client->save;
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'MF client cannot create a real financial_stp account - even if they are professionals'
    );
    $client->status->clear_professional;
    $client->save;
};

subtest 'VR account types - CR residence' => sub {
    my $client = create_client('VRTC');
    $client->set_default_account('USD');
    $client->residence('ai');
    $client->save();

    my $user = BOM::User->create(
        email    => 'vrtc+cr@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo account
    my $login = create_mt5_account->(
        $c, $token, $client,
        {
            country      => 'ai',
            account_type => 'demo'
        });
    ok($login, 'demo account successfully created for a virtual account');
    is $mt5_account_info->{group}, 'demo\p01_ts01\synthetic\svg_std_usd', 'correct VRTC gaming account';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        });
    is $mt5_account_info->{group}, 'demo\p01_ts01\financial\svg_std_usd', 'correct VRTC financial demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        });
    is $mt5_account_info->{group}, 'demo\p01_ts01\financial\labuan_stp_usd', 'correct VRTC financial_stp demo group';

    #real accounts
    create_mt5_account->(
        $c, $token, $client, {account_type => 'gaming'},
        'AccountShouldBeReal', 'Real gaming MT5 account creation is not allowed from a virtual account'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'AccountShouldBeReal',
        'Real financial MT5 account creation is not allowed from a virtual account'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        },
        'AccountShouldBeReal',
        'Real financial_stp MT5 account creation is not allowed from a virtual account'
    );

};

subtest 'Virtual account types - EU residences' => sub {
    my $client = create_client('VRTC');
    $client->set_default_account('USD');
    $client->residence('de');
    $client->save();

    my $user = BOM::User->create(
        email    => 'vrtc+eu@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo account
    my $login = create_mt5_account->(
        $c, $token, $client,
        {
            country      => 'mt',
            account_type => 'demo'
        },
        'MT5NotAllowed',
        'Gaming MT5 account is not available for EU residents'
    );

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        });
    is $mt5_account_info->{group}, 'demo\p01_ts01\financial\maltainvest_std_eur', 'correct VRTC financial demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'Financial STP MT5 account is not available in this country'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'AccountShouldBeReal',
        'Real financial MT5 account creation is not allowed from a virtual account'
    );
};

subtest 'Real account types - EU residences' => sub {
    my $client = create_client('CR');
    $client->set_default_account('USD');
    $client->residence('de');
    $client->save();

    my $user = BOM::User->create(
        email    => 'cr+eu@deriv.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #real accounts
    create_mt5_account->(
        $c, $token, $client, {account_type => 'gaming'},
        'MT5NotAllowed', 'Real gaming MT5 account creation is not allowed in the country of residence'
    );

    my $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'Financial STP MT5 account is not available in this country'
    );

    my $mf_client = create_client('MF');
    $mf_client->set_default_account('GBP');
    $mf_client->residence('de');
    $mf_client->tax_residence('de');
    $mf_client->tax_identification_number('1234');
    $mf_client->account_opening_reason('speculative');
    financial_assessment($mf_client, 'full');
    $mf_client->save();

    $user->add_client($mf_client);

    $login = create_mt5_account->(
        $c, $token,
        $mf_client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        });
    is $mt5_account_info->{group}, 'real\p01_ts01\financial\maltainvest_std-hr_gbp', 'correct financial real group with eur currency';
};

subtest 'Virtual account types - GB residence' => sub {
    my $client = create_client('VRTC');
    $client->set_default_account('USD');
    $client->residence('gb');
    $client->save();

    my $user = BOM::User->create(
        email    => 'vrtc+gb@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo account
    $client->status->clear_age_verification();
    $client->save();
    my $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        },
        'InvalidAccountRegion',
        'Sorry, account opening is unavailable in your region.'
    );

    $client->status->set('age_verification', 'test', 'test');
    $client->save();

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            country      => 'mt',
            account_type => 'demo',
        },
        'InvalidAccountRegion',
        'Sorry, account opening is unavailable in your region.'
    );

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        },
        'InvalidAccountRegion',
        'Sorry, account opening is unavailable in your region.'
    );

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        },
        'InvalidAccountRegion',
        'Sorry, account opening is unavailable in your region.'
    );
};

subtest 'Real account types - GB residence' => sub {
    my $client = create_client('CR');
    $client->set_default_account('USD');
    $client->residence('gb');
    $client->save();

    my $user = BOM::User->create(
        email    => 'cr+gb@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #real accounts
    $client->status->clear_age_verification();
    $client->save();
    create_mt5_account->(
        $c, $token, $client, {account_type => 'gaming'},
        'InvalidAccountRegion', 'Sorry, account opening is unavailable in your region.'
    );

    $client->status->set('age_verification', 'test', 'test');
    $client->save();
    create_mt5_account->(
        $c, $token, $client, {account_type => 'gaming'},
        'InvalidAccountRegion', 'Sorry, account opening is unavailable in your region.'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'InvalidAccountRegion',
        'Sorry, account opening is unavailable in your region.'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        },
        'InvalidAccountRegion',
        'Sorry, account opening is unavailable in your region.'
    );
};

my %lc_company_specific_details = (
    CR => {
        email_prefix => "vrtc+cr2",
        residence    => "id"
    },
    MF => {
        email_prefix => "vrtc+mf2",
        residence    => "de"
    },
    MLT => {
        email_prefix => "vrtc+mlt2",
        residence    => "at"
    });
my ($email, $user, $vr_client, $client, $token_vr, $email_prefix, $residence);
foreach my $broker_code (keys %lc_company_specific_details) {
    subtest $broker_code. ': No real account enabled' => sub {
        $email_prefix = $lc_company_specific_details{$broker_code}{email_prefix};
        $residence    = $lc_company_specific_details{$broker_code}{residence};
        $email        = $email_prefix . '@binary.com';
        $user         = BOM::User->create(
            email    => $email,
            password => 'Abcd33@!',
        );
        $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'VRTC',
            email          => $email,
            residence      => $residence,
            binary_user_id => $user->id
        });

        $user->add_client($vr_client);
        $token_vr = BOM::Platform::Token::API->new->create_token($vr_client->loginid, 'test token');
        $vr_client->set_default_account('USD');

        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => $broker_code,
            email          => $email,
            residence      => $residence,
            binary_user_id => $user->id
        });
        $user->add_client($client);
        $client->status->set('disabled', 'system', 'test');
        $client->save;
        ok $client->status->disabled, "real account is disabled";

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token_vr,
            args     => {
                mainPassword   => 'Abcd33@!',
                investPassword => 'Abcd345435@!',
            },
        };
        my $error_code = 'AccountShouldBeReal';
        my $message    = " MT5 account creation is not allowed from a virtual account since $broker_code account is ";

        create_mt5_account->(
            $c,
            $token_vr,
            $vr_client,
            {
                account_type     => 'financial',
                mt5_account_type => 'financial'
            },
            $error_code,
            'Real financial ' . $message . ' disabled'
        );

        #only CR can create gaming & financial advance account
        if ($broker_code eq 'CR') {
            create_mt5_account->($c, $token_vr, $vr_client, {account_type => 'gaming'}, $error_code, 'Real financial ' . $message . ' disabled');
            create_mt5_account->(
                $c,
                $token_vr,
                $vr_client,
                {
                    account_type     => 'financial',
                    mt5_account_type => 'financial_stp'
                },
                $error_code,
                'Real financial_stp ' . $message . ' disabled'
            );
        }
        $client->status->clear_disabled;
        $client->save;
        $client->status->set('duplicate_account', 'system', 'test');
        $client->save;
        ok $client->status->duplicate_account, "real account is duplicate_account";
        create_mt5_account->(
            $c,
            $token_vr,
            $vr_client,
            {
                account_type     => 'financial',
                mt5_account_type => 'financial'
            },
            $error_code,
            'Real financial ' . $message . ' duplicate'
        );

        #only CR can create gaming & financial advance account
        if ($broker_code eq 'CR') {
            create_mt5_account->($c, $token_vr, $vr_client, {account_type => 'gaming'},, $error_code, 'Real financial ' . $message . ' disabled');
            create_mt5_account->(
                $c,
                $token_vr,
                $vr_client,
                {
                    account_type     => 'financial',
                    mt5_account_type => 'financial_stp'
                },
                $error_code,
                'Real financial_stp ' . $message . ' disabled'
            );
        }
        $client->status->clear_duplicate_account;
        $client->save;
    };
}

subtest 'High risk, POI expired scenario (fa complete)' => sub {
    my $user = BOM::User->create(
        email    => 'cr+so+risky@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');

    my $client = create_client('CR');
    $client->set_default_account('USD');
    $client->account_opening_reason('Speculative');
    $client->place_of_birth('br');
    $client->residence('br');
    $client->aml_risk_classification('high');
    $client->binary_user_id($user->id);
    $client->tax_residence('at');
    $client->tax_identification_number('1234');
    $client->save();
    $user->add_client($client);

    my $mf = create_client('MF');
    $mf->set_default_account('GBP');
    $mf->account_opening_reason('Speculative');
    $mf->place_of_birth('at');
    $mf->residence('at');
    $mf->aml_risk_classification('low');
    $mf->binary_user_id($user->id);
    $mf->tax_residence('at');
    $mf->tax_identification_number('1234');
    $mf->save();
    $user->add_client($mf);

    financial_assessment($mf,     'full');
    financial_assessment($client, 'full');

    my $tests = [{
            description      => 'Labuan is not allowed to open carrying expired documents',
            account_type     => 'financial',
            mt5_account_type => 'financial_stp',
            company          => 'labuan',
            error            => 'ExpiredDocumentsMT5',
            status           => {on => [qw/allow_document_upload/]},
        },
        {
            description      => 'DBVI is not allowed to open carrying expired documents',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'bvi',
            error            => 'ExpiredDocumentsMT5',
            status           => {on => [qw/allow_document_upload/]},
        },
        {
            description      => 'Vanuatu is not allowed to open carrying expired documents',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'vanuatu',
            error            => 'ExpiredDocumentsMT5',
            status           => {on => [qw/allow_document_upload/]},
        },
        {
            description      => 'Malatainvest is not allowed to open carrying expired documents',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'maltainvest',
            error            => 'ExpiredDocumentsMT5',
            status           => {on => [qw/allow_document_upload/]},
        },
        {
            description      => 'SVG is allowed to open carrying expired documents',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'svg',
            error            => undef,
            status           => {off => [qw/allow_document_upload/]},
        },
    ];

    for my $test ($tests->@*) {
        my ($description, $error, $status, $country) = @{$test}{qw/description error status country/};
        my $cli = $client;
        $cli = $mf if $test->{company} eq 'maltainvest';

        my $on  = $status->{on}  // [];
        my $off = $status->{off} // [];

        $cli->status->_clear($_) for $on->@*;
        $cli->status->_clear($_) for $off->@*;

        my $token = BOM::Platform::Token::API->new->create_token($cli->loginid, 'test token');

        $documents_expired = 1;

        create_mt5_account->($c, $token, $cli, {%{$test}{qw/account_type mt5_account_type company/}}, $error, $description,);

        $client = BOM::User::Client->new({loginid => $client->loginid});    # avoid cache hits
        ok $client->status->$_,  "Expected status: $_"         for $on->@*;
        ok !$client->status->$_, "Expected not set status: $_" for $off->@*;
    }
};

subtest 'High risk, POI expired scenario (fa incomplete)' => sub {
    my $user = BOM::User->create(
        email    => 'cr+so+risky+nofa@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');

    my $client = create_client('CR');
    $client->set_default_account('USD');
    $client->account_opening_reason('Speculative');
    $client->place_of_birth('br');
    $client->residence('br');
    $client->aml_risk_classification('high');
    $client->binary_user_id($user->id);
    $client->tax_residence('at');
    $client->tax_identification_number('1234');
    $client->save();
    $user->add_client($client);

    my $mf = create_client('MF');
    $mf->set_default_account('GBP');
    $mf->account_opening_reason('Speculative');
    $mf->place_of_birth('at');
    $mf->residence('at');
    $mf->aml_risk_classification('low');
    $mf->binary_user_id($user->id);
    $mf->tax_residence('at');
    $mf->tax_identification_number('1234');
    $mf->save();
    $user->add_client($mf);

    my $tests = [{
            description      => 'Labuan requires FA',
            account_type     => 'financial',
            mt5_account_type => 'financial_stp',
            company          => 'labuan',
            error            => 'FinancialAssessmentRequired',
            status           => {off => [qw/allow_document_upload/]},
        },
        {
            description      => 'DBVI requires FA',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'bvi',
            error            => 'FinancialAssessmentRequired',
            status           => {off => [qw/allow_document_upload/]},
        },
        {
            description      => 'Vanuatu requires FA',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'vanuatu',
            error            => 'FinancialAssessmentRequired',
            status           => {off => [qw/allow_document_upload/]},
        },
        {
            description      => 'Malatainvest requires FA',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'maltainvest',
            error            => 'FinancialAssessmentRequired',
            status           => {off => [qw/allow_document_upload/]},
        },
        {
            description      => 'SVG requires FA',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'svg',
            error            => 'FinancialAssessmentRequired',
            status           => {off => [qw/allow_document_upload/]},
        },
    ];

    for my $test ($tests->@*) {
        my ($description, $error, $status, $country) = @{$test}{qw/description error status country/};
        my $cli = $client;
        $cli = $mf if $test->{company} eq 'maltainvest';

        my $on  = $status->{on}  // [];
        my $off = $status->{off} // [];

        $cli->status->_clear($_) for $on->@*;
        $cli->status->_clear($_) for $off->@*;

        my $token = BOM::Platform::Token::API->new->create_token($cli->loginid, 'test token');

        $documents_expired = 1;

        create_mt5_account->($c, $token, $cli, {%{$test}{qw/account_type mt5_account_type company/}}, $error, $description,);

        $client = BOM::User::Client->new({loginid => $client->loginid});    # avoid cache hits
        ok $client->status->$_,  "Expected status: $_"         for $on->@*;
        ok !$client->status->$_, "Expected not set status: $_" for $off->@*;
    }
};

subtest 'Low risk, POI expired scenario' => sub {
    my $user = BOM::User->create(
        email    => 'any+not+so+risky@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');

    my $client = create_client('CR');
    $client->set_default_account('USD');
    $client->account_opening_reason('Speculative');
    $client->place_of_birth('br');
    $client->residence('br');
    $client->aml_risk_classification('low');
    $client->binary_user_id($user->id);
    $client->tax_residence('at');
    $client->tax_identification_number('1234');
    $client->save();
    $user->add_client($client);

    my $mf = create_client('MF');
    $mf->set_default_account('GBP');
    $mf->account_opening_reason('Speculative');
    $mf->place_of_birth('at');
    $mf->residence('at');
    $mf->aml_risk_classification('low');
    $mf->binary_user_id($user->id);
    $mf->tax_residence('at');
    $mf->tax_identification_number('1234');
    $mf->save();
    $user->add_client($mf);

    financial_assessment($mf, 'full');

    my $tests = [{
            description      => 'Labuan is not allowed to open carrying expired documents',
            account_type     => 'financial',
            mt5_account_type => 'financial_stp',
            company          => 'labuan',
            error            => 'ExpiredDocumentsMT5',
            status           => {on => [qw/allow_document_upload/]},
        },
        {
            description      => 'DBVI is not allowed to open carrying expired documents',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'bvi',
            error            => 'ExpiredDocumentsMT5',
            status           => {on => [qw/allow_document_upload/]},
        },
        {
            description      => 'Vanuatu is not allowed to open carrying expired documents',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'vanuatu',
            error            => 'ExpiredDocumentsMT5',
            status           => {on => [qw/allow_document_upload/]},
        },
        {
            description      => 'Malatainvest is not allowed to open carrying expired documents',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'maltainvest',
            error            => 'ExpiredDocumentsMT5',
            status           => {on => [qw/allow_document_upload/]},
        },
        {
            description      => 'SVG is allowed to open carrying expired documents',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'svg',
            error            => undef,
            status           => {off => [qw/allow_document_upload/]},
        },
    ];

    for my $test ($tests->@*) {
        my ($description, $error, $status) = @{$test}{qw/description error status/};
        my $cli = $client;
        $cli = $mf if $test->{company} eq 'maltainvest';

        my $on  = $status->{on}  // [];
        my $off = $status->{off} // [];

        $cli->status->_clear($_) for $on->@*;
        $cli->status->_clear($_) for $off->@*;

        my $token = BOM::Platform::Token::API->new->create_token($cli->loginid, 'test token');

        $documents_expired = 1;

        create_mt5_account->($c, $token, $cli, {%{$test}{qw/account_type mt5_account_type company/}}, $error, $description,);

        $client = BOM::User::Client->new({loginid => $client->loginid});    # avoid cache hits
        ok $client->status->$_,  "Expected status: $_"         for $on->@*;
        ok !$client->status->$_, "Expected not set status: $_" for $off->@*;
    }

    $documents_expired = 0;
};

subtest 'Any client, TIN is mandatory' => sub {
    my $user = BOM::User->create(
        email    => 'tin+mandatory+test@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');

    my $client = create_client('CR');
    $client->set_default_account('USD');
    $client->account_opening_reason('Speculative');
    $client->place_of_birth('br');
    $client->residence('br');
    $client->aml_risk_classification('low');
    $client->binary_user_id($user->id);
    $client->tax_residence('at');
    $client->tax_identification_number('1234');
    $client->save();
    $user->add_client($client);

    my $mf = create_client('MF');
    $mf->set_default_account('GBP');
    $mf->account_opening_reason('Speculative');
    $mf->place_of_birth('at');
    $mf->residence('at');
    $mf->aml_risk_classification('low');
    $mf->binary_user_id($user->id);
    $mf->tax_residence('at');
    $mf->tax_identification_number('1234');
    $mf->save();
    $user->add_client($mf);

    financial_assessment($mf, 'full');

    my $tests = [{
            description      => 'Labuan is not allowed to open without TIN details',
            account_type     => 'financial',
            mt5_account_type => 'financial_stp',
            company          => 'labuan',
            error            => 'TINDetailsMandatory',
        },
        {
            description      => 'DBVI is not allowed to open without TIN details',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'bvi',
            error            => 'TINDetailsMandatory',
        },
        {
            description      => 'Vanuatu is not allowed to open without TIN details',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'vanuatu',
            error            => 'TINDetailsMandatory',
        },
        {
            description      => 'Malatainvest is allowed to open without TIN details',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'maltainvest',
            error            => undef,
        },
        {
            description      => 'SVG is allowed to open without TIN details',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'svg',
            error            => undef,
        },
    ];

    for my $test ($tests->@*) {
        my ($description, $error) = @{$test}{qw/description error/};
        my $cli = $client;
        $cli = $mf if $test->{company} eq 'maltainvest';

        $cli->status->_clear('crs_tin_information');

        my $token = BOM::Platform::Token::API->new->create_token($cli->loginid, 'test token');

        create_mt5_account->($c, $token, $cli, {%{$test}{qw/account_type mt5_account_type company/}}, $error, $description,);

    }
};

subtest 'High risk clients, POA is outdated' => sub {
    # this naughy mock was blocking the status update, muk use acid!
    $mocked_user->mock(
        'update_loginid_status' => sub {
            return $mocked_user->original('update_loginid_status')->(@_);
        });

    my $client_mock = Test::MockModule->new('BOM::User::Client');

    $client_mock->mock(
        'get_poa_status',
        sub {
            return 'expired';
        });

    $client_mock->mock(
        'get_poi_status_jurisdiction',
        sub {
            return 'verified';
        });

    my $user = BOM::User->create(
        email    => 'poa+outdated+highrisk@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');

    my $client = create_client('CR');
    $client->set_default_account('USD');
    $client->account_opening_reason('Speculative');
    $client->place_of_birth('br');
    $client->residence('br');
    $client->aml_risk_classification('high');
    $client->binary_user_id($user->id);
    $client->tax_residence('at');
    $client->tax_identification_number('1234');
    financial_assessment($client, 'financial_info');
    $client->save();
    $user->add_client($client);

    my $mf = create_client('MF');
    $mf->set_default_account('GBP');
    $mf->account_opening_reason('Speculative');
    $mf->place_of_birth('at');
    $mf->residence('at');
    $mf->aml_risk_classification('high');
    $mf->binary_user_id($user->id);
    $mf->tax_residence('at');
    $mf->tax_identification_number('1234');
    $mf->save();
    $user->add_client($mf);

    financial_assessment($mf, 'full');

    my $tests = [{
            description      => 'Labuan',
            account_type     => 'financial',
            mt5_account_type => 'financial_stp',
            company          => 'labuan',
            status           => 'proof_failed',
        },
        {
            description      => 'DBVI',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'bvi',
            status           => 'poa_outdated',
        },
        {
            description      => 'Vanuatu',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'vanuatu',
            status           => 'poa_outdated',
        },
        {
            description      => 'Malatainvest',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'maltainvest',
            status           => undef,
        },
        {
            description      => 'SVG',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'svg',
            status           => undef,
        },
    ];

    for my $test ($tests->@*) {
        my ($description, $status) = @{$test}{qw/description status/};

        subtest $description => sub {
            my $cli = $client;
            $cli = $mf if $test->{company} eq 'maltainvest';

            my $token = BOM::Platform::Token::API->new->create_token($cli->loginid, 'test token');

            my $loginid = create_mt5_account->($c, $token, $cli, {%{$test}{qw/account_type mt5_account_type company/}});

            $user->{loginid_details} = undef;    # avoid the cache

            my $loginid_details = $user->loginid_details;

            my $mt5 = $loginid_details->{$loginid};

            my $status_str = $status // 'undef';
            is $mt5->{status}, $status, "Expected $status_str status for the LC";
        };
    }

    $client_mock->unmock_all;
};

subtest 'Low risk clients, POA is outdated' => sub {
    $mocked_user->mock(
        'update_loginid_status' => sub {
            return $mocked_user->original('update_loginid_status')->(@_);
        });

    my $client_mock = Test::MockModule->new('BOM::User::Client');

    $client_mock->mock(
        'get_poa_status',
        sub {
            return 'expired';
        });

    # this naughy mock was throwing poa_failed instead of the expected result
    $client_mock->mock(
        'get_poi_status_jurisdiction',
        sub {
            return 'verified';
        });

    my $user = BOM::User->create(
        email    => 'poa+outdated+lowrisk@binary.com',
        password => 'Abcd33@!',
    );
    $user->update_trading_password('Abcd33@!');

    my $client = create_client('CR');
    $client->set_default_account('USD');
    $client->account_opening_reason('Speculative');
    $client->place_of_birth('br');
    $client->residence('br');
    $client->aml_risk_classification('low');
    $client->binary_user_id($user->id);
    $client->tax_residence('at');
    $client->tax_identification_number('1234');
    $client->save();
    $user->add_client($client);

    my $mf = create_client('MF');
    $mf->set_default_account('GBP');
    $mf->account_opening_reason('Speculative');
    $mf->place_of_birth('at');
    $mf->residence('at');
    $mf->aml_risk_classification('low');
    $mf->binary_user_id($user->id);
    $mf->tax_residence('at');
    $mf->tax_identification_number('1234');
    $mf->save();
    $user->add_client($mf);

    financial_assessment($mf, 'full');

    my $tests = [{
            description      => 'Labuan',
            account_type     => 'financial',
            mt5_account_type => 'financial_stp',
            company          => 'labuan',
            status           => 'proof_failed',
        },
        {
            description      => 'DBVI',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'bvi',
            status           => 'poa_outdated',
        },
        {
            description      => 'Vanuatu',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'vanuatu',
            status           => 'poa_outdated',
        },
        {
            description      => 'Malatainvest',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'maltainvest',
            status           => undef,
        },
        {
            description      => 'SVG',
            account_type     => 'financial',
            mt5_account_type => 'financial',
            company          => 'svg',
            status           => undef,
        },
    ];

    for my $test ($tests->@*) {
        my ($description, $status) = @{$test}{qw/description status/};

        subtest $description => sub {
            my $cli = $client;
            $cli = $mf if $test->{company} eq 'maltainvest';

            my $token = BOM::Platform::Token::API->new->create_token($cli->loginid, 'test token');

            my $loginid = create_mt5_account->($c, $token, $cli, {%{$test}{qw/account_type mt5_account_type company/}});

            $user->{loginid_details} = undef;    # avoid the cache

            my $loginid_details = $user->loginid_details;

            my $mt5 = $loginid_details->{$loginid};

            my $status_str = $status // 'undef';

            if (defined $status and $status eq 'poa_outdated') {
                is $mt5->{status}, 'poa_pending', "Expected poa_pending status when $status_str for low risk LC";
            } else {
                is $mt5->{status}, $status, "Expected $status_str status for the LC";
            }
        };
    }

    $client_mock->unmock_all;
};

sub create_mt5_account {
    my ($c, $token, $client, $args, $expected_error, $error_message) = @_;

    $client->user->update_trading_password('Abcd33@!') unless $client->user->trading_password;

    undef @emit_args;
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'demo',
            #mt5_account_type => 'financial',
            country        => 'mt',
            email          => 'test.account@binary.com',
            name           => 'MT5 lover',
            investPassword => 'Abcd311233@!',
            mainPassword   => 'Abcd33@!',
            leverage       => 100,
        },
    };

    foreach (keys %$args) { $params->{args}->{$_} = $args->{$_} }

    $mt5_account_info = {};

    my $result = $c->call_ok('mt5_new_account', $params);

    if ($expected_error) {
        $result->has_error->error_code_is($expected_error, $error_message);
        is scalar @emit_args, 0, 'No event is emitted for failed requests';
        return $c->result->{error};
    } else {
        $result->has_no_error;
        ok $mt5_account_info, 'mt5 api is called';

        is_deeply \@emit_args,
            [
            'new_mt5_signup',
            {
                cs_email         => 'support@binary.com',
                language         => 'EN',
                loginid          => $client->loginid,
                mt5_group        => $mt5_account_info->{group},
                mt5_login_id     => $c->result->{login},
                account_type     => $params->{args}->{account_type}     // '',
                sub_account_type => $params->{args}->{mt5_account_type} // '',
            },
            ];
        return $c->result->{login};
    }
}

sub financial_assessment {
    my ($client, $type) = @_;
    my %data;
    if ($client->landing_company->short eq 'maltainvest') {
        %data = map { $_ => $financial_data_mf{$_} } ($assessment_keys_mf->{$type}->@*);
        %data = %financial_data_mf if $type eq 'full';
    } else {
        %data = map { $_ => $financial_data{$_} } ($assessment_keys->{$type}->@*);
        %data = %financial_data if $type eq 'full';
    }

    $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%data)});
    $client->save();

}

sub authenticate {
    my ($client) = shift;

    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client->save();
}

$mocked_mt5->unmock_all;

# reset
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02($p01_ts02_load);
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03($p01_ts03_load);

done_testing();
