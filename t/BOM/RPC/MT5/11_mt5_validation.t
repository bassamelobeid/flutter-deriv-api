use strict;
use warnings;
use feature 'state';

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Locale::Country::Extra;

use BOM::Test::RPC::QueueClient;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client qw(create_client);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User;
use BOM::Database::Model::OAuth;
use BOM::User::Password;
use Email::Stuffer::TestLinks;

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
            'group'    => $mt5_account_info->{group} // 'demo\svg',
            'currency' => 'USD',
            'leverage' => 500
        });
    },
    'get_user' => sub {
        my $country_name = $mt5_account_info->{country} ? Locale::Country::Extra->new()->country_from_code($mt5_account_info->{country}) : '';
        return Future->done({%$mt5_account_info, country => $country_name // $mt5_account_info->{country}});
    },
);

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

    my $user = BOM::User->create(
        email    => 'test.account@binary.com',
        password => 'Abcd33@!',
    );
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

    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->all(1);
    $c->call_ok($method, $params)->has_error->error_code_is('MT5APISuspendedError', 'MT5 calls are suspended error message');

    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->all(0);

    $params->{args}->{account_type} = undef;
    $c->call_ok($method, $params)->has_error->error_code_is('InvalidAccountType', 'Correct error message for undef account type');
    $params->{args}->{account_type} = 'dummy';
    $c->call_ok($method, $params)->has_error->error_code_is('InvalidAccountType', 'Correct error message for invalid account type');
    $params->{args}->{account_type} = 'demo';

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    my $citizen = $test_client->citizen;

    $test_client->citizen('');
    $test_client->save;

    $c->call_ok($method, $params)->has_no_error('Citizenship is not required for creating demo accounts');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $params->{args}->{account_type} = 'gaming';
    $c->call_ok($method, $params)->has_no_error('Citizenship is not required for creating gaming accounts');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $params->{args}->{account_type}     = 'financial';
    $params->{args}->{mt5_account_type} = 'financial';

    $c->call_ok($method, $params)->has_no_error('Citizenship is not required for creating financial accounts');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

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

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $params->{args}->{account_type}   = 'demo';
    $params->{args}->{mainPassword}   = 'Abcd33@!';
    $params->{args}->{investPassword} = 'Abcd33@!';
    $c->call_ok($method, $params)->has_error->error_message_is('Please use different passwords for your investor and main accounts.',
        'Correct error message for same password');

    $params->{args}->{mainPassword} = 'Test1@binary.com';
    $c->call_ok($method, $params)->has_error->error_code_is('MT5PasswordEmailLikenessError')
        ->error_message_is('You cannot use your email address as your password.', 'Correct error message for using email as mainPassword');
    $params->{args}->{mainPassword} = 'Abcd33@!';

    $params->{args}->{mainPassword} = '123sdadasd';
    $c->call_ok($method, $params)->has_error->error_code_is('IncorrectMT5PasswordFormat')
        ->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'Correct error message for using weak mainPassword');
    $params->{args}->{mainPassword} = 'Abcd33@!';

    $params->{args}->{investPassword} = '123sdadasd';
    $c->call_ok($method, $params)->has_error->error_code_is('IncorrectMT5PasswordFormat')
        ->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'Correct error message for using weak investPassword');

    $params->{args}->{investPassword} = 'Test1@binary.com';
    $c->call_ok($method, $params)->has_error->error_code_is('MT5PasswordEmailLikenessError')
        ->error_message_is('You cannot use your email address as your password.', 'Correct error message for using email as investPassword');

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

        # Throttle function limits requests to 1 per minute which may cause
        # consecutive tests to fail without a reset.
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok($method, $params)->has_no_error();
        like($c->response->{rpc_response}->{result}->{login}, qr/[0-9]+/, 'Should return MT5 ID');
    }
};

subtest 'CR account types - low risk' => sub {
    my $client = create_client('CR');
    $client->set_default_account('USD');
    $client->place_of_birth('af');
    $client->residence('af');
    $client->aml_risk_classification('low');
    $client->save();

    my $user = BOM::User->create(
        email    => 'cr+low@binary.com',
        password => 'Abcd33@!',
    );
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
    is $mt5_account_info->{country}, 'Afghanistan', 'requested country was masked by client_s country of residence';
    is $mt5_account_info->{group},   'demo\svg',    'correct CR demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        });
    is $mt5_account_info->{group}, 'demo\svg_financial', 'correct CR financial demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        });
    is $mt5_account_info->{group}, 'demo\labuan_financial_stp', 'correct CR financial_stp demo group';

    #real accounts
    financial_assessment($client, 'none');
    $login = create_mt5_account->($c, $token, $client, {account_type => 'gaming'});
    is $mt5_account_info->{group}, 'real\svg', 'correct CR gaming group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        });
    ok $login, 'financial mt5 account is created without authentication and FA';
    is $mt5_account_info->{group}, 'real\svg_financial_Bbook', 'correct CR financial group';

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
        'AuthenticateAccount',
        'authentication is required for financial_stp mt5 accounts'
    );
    authenticate($client);

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        });
    ok $login, 'financial_stp account created without financial assessment';
    is $mt5_account_info->{group}, 'real\labuan_financial_stp', 'correct CR financial_stp group';
};

subtest 'CR account types - high risk' => sub {
    my $user = BOM::User->create(
        email    => 'cr+high@binary.com',
        password => 'Abcd33@!',
    );

    my $client = create_client('CR');
    $client->set_default_account('USD');
    $client->place_of_birth('af');
    $client->residence('af');
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
    is $mt5_account_info->{group}, 'demo\svg', 'correct CR demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        });
    is $mt5_account_info->{group}, 'demo\svg_financial', 'correct CR financial demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        });
    is $mt5_account_info->{group}, 'demo\labuan_financial_stp', 'correct CR financial_stp demo group';

    #real accounts

    financial_assessment($client, 'none');
    create_mt5_account->(
        $c, $token, $client,
        {account_type => 'gaming'},
        'FinancialAssessmentMandatory',
        'Financial assessment is required for high risk clients'
    );

    financial_assessment($client, 'financial_info');
    $login = create_mt5_account->($c, $token, $client, {account_type => 'gaming'});
    ok $login, 'gaming account created with finantial information alone';
    is $mt5_account_info->{group}, 'real\svg', 'correct CR gaming group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        });
    ok $login, 'financial mt5 account is created without authentication';
    is $mt5_account_info->{group}, 'real\svg_financial_Bbook', 'correct CR financial group';

    my $error = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        },
        'ASK_FIX_DETAILS',
        'Required fields missing for financial_stp account'
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
        'AuthenticateAccount',
        'authentication is required by labuan'
    );

    authenticate($client);
    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        });
    ok $login, 'financial_stp account created without full financial assessment';
    is $mt5_account_info->{group}, 'real\labuan_financial_stp', 'correct CR labuan_financial_stp group';
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
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo account
    my $login = create_mt5_account->($c, $token, $client, {account_type => 'demo'});
    ok($login, 'demo account successfully created for a low risk client');
    is $mt5_account_info->{group}, 'demo\malta', 'correct MLT demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        });
    ok $login, 'MLT client can create a financial demo account';
    is $mt5_account_info->{group}, 'demo\maltainvest_financial', 'correct MLT demo group';

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
    $login = create_mt5_account->($c, $token, $client, {account_type => 'gaming'});
    is $mt5_account_info->{group}, 'real\malta', 'correct MLT gaming group';

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
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo account
    my $login = create_mt5_account->($c, $token, $client, {account_type => 'demo'});
    ok($login, 'demo account successfully created for a high risk client');
    is $mt5_account_info->{group}, 'demo\malta', 'correct MLT demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        });
    ok $login, 'MLT client can create a financial demo account';
    is $mt5_account_info->{group}, 'demo\maltainvest_financial', 'correct MLT demo group';

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
    create_mt5_account->(
        $c, $token, $client,
        {account_type => 'gaming'},
        'FinancialAssessmentMandatory',
        'Financial assessment required for high risk clients'
    );

    financial_assessment($client, 'financial_info');
    $login = create_mt5_account->($c, $token, $client, {account_type => 'gaming'});
    is $mt5_account_info->{group}, 'real\malta', 'correct MLT gaming group';

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
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo accounts
    my $login = create_mt5_account->($c, $token, $client, {account_type => 'demo'});
    ok($login, 'demo gaming account successfully created for an MF client');
    is $mt5_account_info->{group}, 'demo\malta', 'correct MF demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        });
    ok($login, 'demo financial account successfully created for an MF client');
    is $mt5_account_info->{group}, 'demo\maltainvest_financial', 'correct MF demo group';

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
    create_mt5_account->(
        $c, $token, $client, {account_type => 'gaming'},
        'GamingAccountMissing', 'MF client cannot create a gaming real account before they have an MLT account'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'FinancialAssessmentMandatory',
        'Financial assessment is required for MF clients'
    );

    financial_assessment($client, 'financial_info');
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'FinancialAssessmentMandatory',
        'Financial info is not enough for MF clients'
    );

    financial_assessment($client, 'trading_experience');
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'FinancialAssessmentMandatory',
        'Trading experience is not enough for MF clients'
    );

    financial_assessment($client, 'full');
    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        });
    ok($login, 'real financial account successfully created for an MF client');
    is $mt5_account_info->{group}, 'real\maltainvest_financial', 'correct MF financial group';

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

subtest 'MX account types' => sub {
    my $client = create_client('MX');
    $client->set_default_account('EUR');
    $client->residence('gb');
    $client->save();

    my $user = BOM::User->create(
        email    => 'mx+gb@binary.com',
        password => 'Abcd33@!',
    );
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo accounts
    create_mt5_account->($c, $token, $client, {account_type => 'demo'}, 'MT5NotAllowed', 'MX clients cannot create demo gaming account');

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        },
        'FinancialAccountMissing',
        'MX client cannot create mt5 financial_stp demo account without any MF sibling'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'MX client cannot create mt5 financial_stp demo account'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type => 'demo',
        },
        'MT5NotAllowed',
        'MX client cannot create mt5 gaming demo account'
    );

    my $mf_client = create_client('MF');
    $mf_client->set_default_account('EUR');

    $mf_client->residence('de');
    $mf_client->tax_residence('de');
    $mf_client->tax_identification_number('1234');
    $mf_client->account_opening_reason('speculative');
    $client->aml_risk_classification('low');
    financial_assessment($mf_client, 'full');
    $mf_client->save();

    $user->add_client($mf_client);
    $token = BOM::Platform::Token::API->new->create_token($mf_client->loginid, 'test token');

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'gaming',
            mt5_account_type => 'financial'
        },
        'MT5NotAllowed',
        'MF client upgraded from MX cannot create mt5 gaming account'
    );

    #demo account
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type => 'demo',
        },
        'MT5NotAllowed',
        'MF clients cannot create demo gaming account'
    );
};

subtest 'VR account types - CR residence' => sub {
    my $client = create_client('VRTC');
    $client->set_default_account('USD');
    $client->residence('af');
    $client->save();

    my $user = BOM::User->create(
        email    => 'vrtc+cr@binary.com',
        password => 'Abcd33@!',
    );
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo account
    my $login = create_mt5_account->(
        $c, $token, $client,
        {
            country      => 'af',
            account_type => 'demo'
        });
    ok($login, 'demo account successfully created for a virtual account');
    is $mt5_account_info->{group}, 'demo\svg', 'correct VRTC gaming account';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        });
    is $mt5_account_info->{group}, 'demo\svg_financial', 'correct VRTC financial demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        });
    is $mt5_account_info->{group}, 'demo\labuan_financial_stp', 'correct VRTC financial_stp demo group';

    #real accounts
    create_mt5_account->(
        $c, $token, $client, {account_type => 'gaming'},
        'RealAccountMissing', 'Real gaming MT5 account creation is not allowed from a virtual account'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'RealAccountMissing',
        'Real financial MT5 account creation is not allowed from a virtual account'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        },
        'RealAccountMissing',
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
    is $mt5_account_info->{group}, 'demo\maltainvest_financial', 'correct VRTC financial demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'Financial STP MT5 account is not available in this country'
    );

    #real accounts
    create_mt5_account->(
        $c, $token, $client, {account_type => 'gaming'},
        'MT5NotAllowed', 'Real gaming MT5 account creation is not allowed in the country of residence'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'RealAccountMissing',
        'Real financial MT5 account creation is not allowed from a virtual account'
    );

    create_mt5_account->(
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
    BOM::RPC::v3::MT5::Account::reset_throttler($mf_client->loginid);
    $login = create_mt5_account->(
        $c, $token,
        $mf_client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        });
    is $mt5_account_info->{group}, 'real\maltainvest_financial_GBP', 'correct VRTC financial demo group with GBP currency';

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
    $user->add_client($client);
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    #demo account
    $client->status->clear_age_verification();
    $client->save();
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        },
        'FinancialAccountMissing',
        'Virtual GB client cannot create a financial MT5 account'
    );
    $client->status->set('age_verification', 'test', 'test');
    $client->save();

    my $login = create_mt5_account->(
        $c, $token, $client,
        {
            country      => 'mt',
            account_type => 'demo',
        },
        'MT5NotAllowed',
        'Virtual GB client can not create gaming demo account'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial'
        },
        'FinancialAccountMissing',
        'Unable to create MT5 financial account from GB even after age verification'
    );

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'Financial STP demo MT5 account is not available in this country'
    );

    #real accounts
    $client->status->clear_age_verification();
    $client->save();
    create_mt5_account->(
        $c, $token, $client, {account_type => 'gaming'},
        'MT5NotAllowed', 'Real gaming MT5 account creation is not allowed from a virtual account for GB residence'
    );

    $client->status->set('age_verification', 'test', 'test');
    $client->save();
    create_mt5_account->(
        $c, $token, $client, {account_type => 'gaming'},
        'MT5NotAllowed', 'Real gaming MT5 account creation is not allowed from a virtual account for GB residence ( even if age verified)'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial'
        },
        'RealAccountMissing',
        'Real financial MT5 account creation is not allowed from a virtual account'
    );

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp'
        },
        'MT5NotAllowed',
        'Financial STP MT5 account is not available in this country'
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
    },
    MX => {
        email_prefix => "vrtc+mx2",
        residence    => "gb"
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
        my $error_code = 'RealAccountMissing';
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

sub create_mt5_account {
    my ($c, $token, $client, $args, $expected_error, $error_message) = @_;

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
    BOM::RPC::v3::MT5::Account::reset_throttler($client->loginid);
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
                account_type     => $params->{args}->{account_type} // '',
                sub_account_type => $params->{args}->{mt5_account_type} // '',
            }];
        return $c->result->{login};
    }
}

sub financial_assessment {
    my ($client, $type) = @_;

    my %data = map { $_ => $financial_data{$_} } ($assessment_keys->{$type}->@*);
    %data = %financial_data if $type eq 'full';

    $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%data)});
    $client->save();

}

sub authenticate {
    my ($client) = shift;

    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client->save();
}

$mocked_mt5->unmock_all;

done_testing();

