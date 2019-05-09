use strict;
use warnings;
use feature 'state';

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Locale::Country::Extra;

use BOM::Test::RPC::Client;
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

#mocking this module will let us avoid making calls to MT5 server.
my $mt5_account_info;
my $mocked_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
$mocked_mt5->mock(
    'create_user' => sub {
        state $count = 1000;
        $mt5_account_info = {shift->%*};
        return Future->done({login => $count++});
    },
    'deposit' => sub {
        return Future->done({status => 1});
    },
    'get_group' => sub {
        return Future->done({
            'group' => $mt5_account_info->{group} // 'demo\svg',
            'currency' => 'USD',
            'leverage' => 500
        });
    },
    'get_user' => sub {
        my $country_name = Locale::Country::Extra->new()->country_from_code($mt5_account_info->{country});
        return Future->done({%$mt5_account_info, country => $country_name // $mt5_account_info->{country}});
    },
);

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

subtest 'new account' => sub {
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        citizen        => 'at',
        place_of_birth => 'at'
    });
    $test_client->set_default_account('USD');
    $test_client->save();

    my $user = BOM::User->create(
        email    => 'test.account@binary.com',
        password => 'jskjd8292922',
    );
    $user->add_client($test_client);

    my $m = BOM::Database::Model::AccessToken->new;
    my $token = $m->create_token($test_client->loginid, 'test token');

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => 12345,
        args     => {
            mainPassword   => 'Abc1234d',
            investPassword => 'Abcd12345e',
        },
    };
    $c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'check invalid token');

    $params->{token} = $token;

    BOM::Config::Runtime->instance->app_config->system->suspend->mt5(1);
    $c->call_ok($method, $params)->has_error->error_message_is('MT5 API calls are suspended.', 'MT5 calls are suspended error message');

    BOM::Config::Runtime->instance->app_config->system->suspend->mt5(0);

    $params->{args}->{account_type} = undef;
    $c->call_ok($method, $params)->has_error->error_message_is('Invalid account type.', 'Correct error message for undef account type');
    $params->{args}->{account_type} = 'dummy';
    $c->call_ok($method, $params)->has_error->error_message_is('Invalid account type.', 'Correct error message for invalid account type');
    $params->{args}->{account_type} = 'demo';

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    my $citizen = $test_client->citizen;

    $test_client->citizen('');
    $test_client->save;

    $c->call_ok($method, $params)->has_error->error_message_is('Please set citizenship for your account.', 'Citizen not set');

    $test_client->citizen($citizen);
    $test_client->save;

    $params->{args}->{mainPassword}   = 'Abc123';
    $params->{args}->{investPassword} = 'Abc123';
    $c->call_ok($method, $params)
        ->has_error->error_message_is('Investor password cannot be same as main password.', 'Correct error message for same password');

    $params->{args}->{investPassword}   = 'Abc1234';
    $params->{args}->{mt5_account_type} = 'dummy';
    $c->call_ok($method, $params)->has_error->error_message_is('Invalid sub account type.', 'Invalid sub account type error message');

    $params->{args}->{account_type} = 'financial';

    my $pob = $test_client->place_of_birth;

    $test_client->place_of_birth('');
    $test_client->save();

    $c->call_ok($method, $params)->has_error->error_code_is("MissingBasicDetails")->error_message_is("Please fill in your account details")
        ->error_details_is({missing => ["place_of_birth"]});

    $test_client->place_of_birth($pob);
    $test_client->save();

    delete $params->{args}->{mt5_account_type};
    $c->call_ok($method, $params)->has_error->error_message_is('Invalid sub account type.', 'Sub account mandatory for financial');

    $params->{args}->{mt5_account_type} = 'advanced';
    $test_client->aml_risk_classification('high');
    $test_client->save();
    $c->call_ok($method, $params)
        ->has_error->error_message_is('Please complete financial assessment.', 'Financial assessment mandatory for financial account');

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

    $m               = BOM::Database::Model::AccessToken->new;
    $token           = $m->create_token($test_client->loginid, 'test token 2');
    $params->{token} = $token;

    $c->call_ok($method, $params)->has_error->error_message_is('Permission denied.', 'Only svg, malta, maltainvest and champion fx clients allowed.');

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
            password => 'jskjd8292922',
        );
        $user->add_client($test_client);

        $c     = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);
        $m     = BOM::Database::Model::AccessToken->new;
        $token = $m->create_token($test_client->loginid, 'test token');

        # set the params
        $params->{token}                  = $token;
        $params->{args}->{account_type}   = 'demo';
        $params->{args}->{country}        = 'mt';
        $params->{args}->{email}          = 'test.account@binary.com';
        $params->{args}->{name}           = 'J\x{c3}\x{b2}s\x{c3}\x{a9}';
        $params->{args}->{investPassword} = 'Abcd1234';
        $params->{args}->{mainPassword}   = 'Efgh4567';
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
        password => 'jskjd8292922',
    );
    $user->add_client($client);
    my $token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token');

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

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'standard'
        },
        'FinancialAssessmentMandatory',
        'Full financial assessment is required for demo financial accounts'
    );
    financial_assessment($client, 'full');
    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'standard'
        });
    is $mt5_account_info->{group}, 'demo\vanuatu_standard', 'correct CR standard demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'advanced'
        });
    is $mt5_account_info->{group}, 'demo\labuan_advanced', 'correct CR advanced demo group';

    #real accounts
    financial_assessment($client, 'none');
    $login = create_mt5_account->($c, $token, $client, {account_type => 'gaming'});
    is $mt5_account_info->{group}, 'real\svg', 'correct CR gaming group';

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'standard'
        },
        'FinancialAssessmentMandatory',
        'Full financial assessment is required for financial accounts'
    );

    financial_assessment($client, 'full');
    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'standard'
        });
    ok $login, 'financial account created with full financial assessment';
    is $mt5_account_info->{group}, 'real\vanuatu_standard', 'correct CR standard financial group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'advanced'
        });
    ok $login, 'financial account created with full financial assessment';
    is $mt5_account_info->{group}, 'real\labuan_advanced', 'correct CR standard financial group';
};

subtest 'CR account types - high risk' => sub {
    my $user = BOM::User->create(
        email    => 'cr+high@binary.com',
        password => 'jskjd8292922',
    );

    my $client = create_client('CR');
    $client->set_default_account('USD');
    $client->place_of_birth('af');
    $client->residence('af');
    $client->aml_risk_classification('high');
    $client->save();
    $user->add_client($client);
    my $token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token');

    #demo account

    create_mt5_account->(
        $c, $token, $client,
        {account_type => 'demo'},
        'FinancialAssessmentMandatory',
        'Financial assessment needed for high risk clients (even creating a demo MT5 accounts)'
    );
    financial_assessment($client, 'financial_info');
    my $login = create_mt5_account->(
        $c, $token, $client,
        {
            country      => 'mt',
            account_type => 'demo'
        });
    ok($login, 'demo account successfully created for a high risk client');
    is $mt5_account_info->{group}, 'demo\svg', 'correct CR demo group';

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'standard'
        },
        'FinancialAssessmentMandatory',
        'Full financial assessment is required for demo financial accounts'
    );
    financial_assessment($client, 'full');
    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'standard'
        });
    is $mt5_account_info->{group}, 'demo\vanuatu_standard', 'correct CR standard demo group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'advanced'
        });
    is $mt5_account_info->{group}, 'demo\labuan_advanced', 'correct CR advanced demo group';

    #real accounts

    financial_assessment($client, 'none');
    create_mt5_account->(
        $c, $token, $client,
        {account_type => 'gaming'},
        'FinancialAssessmentMandatory',
        'Financial assessment needed for high risk clients'
    );

    financial_assessment($client, 'financial_info');
    $login = create_mt5_account->($c, $token, $client, {account_type => 'gaming'});
    ok $login, 'gaming account created with finantial information alone';
    is $mt5_account_info->{group}, 'real\svg', 'correct CR gaming group';

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'standard'
        },
        'FinancialAssessmentMandatory',
        'Full financial assessment is required for financial accounts'
    );

    financial_assessment($client, 'full');
    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'standard'
        });
    ok $login, 'financial account created with full financial assessment';
    is $mt5_account_info->{group}, 'real\vanuatu_standard', 'correct CR standard financial group';

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'advanced'
        });
    ok $login, 'financial account created with full financial assessment';
    is $mt5_account_info->{group}, 'real\labuan_advanced', 'correct CR standard financial group';
};

subtest 'MLT account types - low risk' => sub {
    my $client = create_client('MLT');
    $client->set_default_account('EUR');
    $client->residence('at');
    $client->aml_risk_classification('low');
    $client->save();

    my $user = BOM::User->create(
        email    => 'mlt+low@binary.com',
        password => 'jskjd8292922',
    );
    $user->add_client($client);
    my $token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token');

    #demo account
    my $login = create_mt5_account->($c, $token, $client, {account_type => 'demo'});
    ok($login, 'demo account successfully created for a low risk client');
    is $mt5_account_info->{group}, 'demo\malta', 'correct MLT demo group';

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'standard'
        },
        'PermissionDenied',
        'MLT client cannot create a standard financial demo account'
    );

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'advanced'
        },
        'PermissionDenied',
        'MLT client cannot create an advanced financial demo account'
    );

    #real accounts
    $login = create_mt5_account->($c, $token, $client, {account_type => 'gaming'});
    is $mt5_account_info->{group}, 'real\malta', 'correct MLT gaming group';

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'standard'
        },
        'PermissionDenied',
        'MLT client cannot create a standard financial real account'
    );

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'advanced'
        },
        'PermissionDenied',
        'MLT client cannot create a advanced financial real account'
    );
};

subtest 'MLT account types - high risk' => sub {
    my $client = create_client('MLT');
    $client->set_default_account('EUR');
    $client->residence('at');
    $client->aml_risk_classification('high');
    $client->save();

    my $user = BOM::User->create(
        email    => 'mlt+high@binary.com',
        password => 'jskjd8292922',
    );
    $user->add_client($client);
    my $token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token');

    #demo account
    create_mt5_account->(
        $c, $token, $client,
        {account_type => 'demo'},
        'FinancialAssessmentMandatory',
        'Financial assessment needed for high risk clients'
    );
    financial_assessment($client, 'financial_info');
    my $login = create_mt5_account->($c, $token, $client, {account_type => 'demo'});
    ok($login, 'demo account successfully created for a high risk client');
    is $mt5_account_info->{group}, 'demo\malta', 'correct MLT demo group';

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'standard'
        },
        'PermissionDenied',
        'MLT client cannot create a standard financial demo account'
    );

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'advanced'
        },
        'PermissionDenied',
        'MLT client cannot create a advanced financial demo account'
    );

    #real accounts
    financial_assessment($client, 'none');
    create_mt5_account->(
        $c, $token, $client,
        {account_type => 'gaming'},
        'FinancialAssessmentMandatory',
        'Financial assessment needed for high risk clients'
    );

    financial_assessment($client, 'financial_info');
    $login = create_mt5_account->($c, $token, $client, {account_type => 'gaming'});
    is $mt5_account_info->{group}, 'real\malta', 'correct MLT gaming group';

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'standard'
        },
        'PermissionDenied',
        'MLT client cannot create a standard financial real account'
    );

    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'advanced'
        },
        'PermissionDenied',
        'MLT client cannot create a advanced financial real account'
    );
};

subtest 'MF accout types' => sub {
    my $client = create_client('MF');
    $client->set_default_account('EUR');
    $client->residence('at');
    $client->aml_risk_classification('low');
    $client->save();

    my $user = BOM::User->create(
        email    => 'mf+low@binary.com',
        password => 'jskjd8292922',
    );
    $user->add_client($client);
    my $token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token');

    #demo account
    create_mt5_account->($c, $token, $client, {account_type => 'demo'}, 'PermissionDenied', 'MF client cannot create a gaming demo account');

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'standard'
        },
        'FinancialAssessmentMandatory',
        'Financial assessment is required for MF clients'
    );
    financial_assessment($client, 'full');

    my $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'standard'
        });
    ok($login, 'demo standard account successfully created for a low risk client');
    is $mt5_account_info->{group}, 'demo\maltainvest_standard', 'correct MF demo group';

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'advanced'
        },
        'PermissionDenied',
        'non-professional MF clients cannot create demo advanced account'
    );

    $client->status->set("professional");
    $client->save;
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'advanced'
        },
        'PermissionDenied',
        'non-professional MF clients cannot create either'
    );
    $client->status->clear_professional;
    $client->save;

    #real accounts
    financial_assessment($client, 'none');
    create_mt5_account->($c, $token, $client, {account_type => 'gaming'}, 'PermissionDenied', 'MF client cannot create a gaming real account');

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'standard'
        },
        'FinancialAssessmentMandatory',
        'Financial assessment is required for MF clients'
    );

    financial_assessment($client, 'financial_info');
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'standard'
        },
        'FinancialAssessmentMandatory',
        'Financial info is not enough for MF clients'
    );

    financial_assessment($client, 'trading_experience');
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'standard'
        },
        'FinancialAssessmentMandatory',
        'Trading experience is not enough for MF clients'
    );

    financial_assessment($client, 'full');
    $login = create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'standard'
        });
    ok($login, 'real standard account successfully created for a low risk MF client');
    is $mt5_account_info->{group}, 'real\maltainvest_standard', 'correct MF standard group';

    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'advanced'
        },
        'PermissionDenied',
        'MF client cannot create a real advanced account'
    );

    $client->status->set("professional");
    $client->save;
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'advanced'
        },
        'PermissionDenied',
        'MF client cannot create a real advanced account - even if they are professionals'
    );
    $client->status->clear_professional;
    $client->save;
};

subtest 'MX account types' => sub {
    my $client = create_client('MX');
    $client->set_default_account('EUR');
    $client->residence('gb');
    $client->aml_risk_classification('low');
    $client->save();

    my $user = BOM::User->create(
        email    => 'mx+low@binary.com',
        password => 'jskjd8292922',
    );
    $user->add_client($client);
    my $token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token');

    #demo accounts
    create_mt5_account->($c, $token, $client, {account_type => 'demo'}, undef, 'MX client can create gaming demo account');
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'standard'
        },
        'PermissionDenied',
        'MX client cannot create standard demo account'
    );
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'demo',
            mt5_account_type => 'advanced'
        },
        'PermissionDenied',
        'MX client cannot create advanced demo account'
    );
    #real accounts
    create_mt5_account->($c, $token, $client, {account_type => 'gaming'}, undef, 'MX client can create any real gaming account');
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type     => 'financial',
            mt5_account_type => 'standard'
        },
        'PermissionDenied',
        'MX client cannot create any real standard account'
    );
    create_mt5_account->(
        $c, $token, $client,
        {
            account_type => 'financial',
            , mt5_account_type => 'advanced'
        },
        'PermissionDenied',
        'MX client cannot create any real advanced account'
    );
};

sub create_mt5_account {
    my ($c, $token, $client, $args, $expected_error, $error_message) = @_;

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'demo',
            #mt5_account_type => 'standard',
            country        => 'mt',
            email          => 'test.account@binary.com',
            name           => 'MT5 lover',
            investPassword => 'Abcd1234',
            mainPassword   => '1234Abcd',
            leverage       => 100,
        },
    };

    foreach (keys %$args) { $params->{args}->{$_} = $args->{$_} }

    BOM::RPC::v3::MT5::Account::reset_throttler($client->loginid);
    my $result = $c->call_ok('mt5_new_account', $params);
    #$expected_error? $result->has_error->error_code_is($expected_error, $error_message): $result->has_no_error;
    if ($expected_error) {
        $result->has_error->error_code_is($expected_error, $error_message);
        return $c->result->{error}->{message_to_client};
    } else {
        $result->has_no_error;
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

$mocked_mt5->unmock_all;

done_testing();
