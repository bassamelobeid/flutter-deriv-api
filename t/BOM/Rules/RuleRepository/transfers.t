use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Runtime;
use BOM::Rules::Engine;
use Format::Util::Numbers qw/formatnumber/;
use BOM::Config::Chronicle;
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);
use ExchangeRates::CurrencyConverter qw/convert_currency/;
my $redis = BOM::Config::Redis::redis_exchangerates_write();
subtest 'rule transfers.currency_should_match' => sub {
    my $rule_name = 'transfers.currency_should_match';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $user = BOM::User->create(
        email    => 'test+cr@test.deriv',
        password => 'TRADING PASS',
    );
    $user->add_client($client);
    $client->account('GBP');

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    my $params      = {
        loginid           => $client->loginid,
        platform_currency => 'USD',
        action            => 'relax'
    };

    ok $rule_engine->apply_rules($rule_name, %$params), 'no error when no currency passed';

    $params->{currency} = 'USD';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'InvalidAction',
        rule       => $rule_name
        },
        'invalid action reported';

    $params->{action} = 'deposit';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'CurrencyShouldMatch',
        rule       => $rule_name
        },
        'expected error when currency mismatch';

    $params->{currency} = 'GBP';
    ok $rule_engine->apply_rules($rule_name, %$params), 'The test passes';

    $params->{action} = 'withdrawal';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'CurrencyShouldMatch',
        rule       => $rule_name
        },
        'expected error when currency mismatch';

    $params->{currency} = 'USD';
    ok $rule_engine->apply_rules($rule_name, %$params), 'The test passes';
};

subtest 'rule transfers.daily_limit' => sub {
    my $rule_name = 'transfers.daily_limit';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $user = BOM::User->create(
        email    => 'test+daily@test.deriv',
        password => 'TRADING PASS',
    );
    $user->add_client($client);
    $client->account('USD');

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    my $params      = {
        loginid  => $client->loginid,
        platform => 'dxtrade'
    };

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade(1);
    $client->user->daily_transfer_incr({type => 'dxtrade'});

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code     => 'MaximumTransfers',
        message_params => [1],
        rule           => $rule_name
        },
        'expected error when limit is hit';

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade(100);
    ok $rule_engine->apply_rules($rule_name, %$params), 'The test passes';

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);

    ok $rule_engine->apply_rules($rule_name, %$params), 'The rule is by-passed using when total limits enabled';

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->derivez(0);
    $params->{platform} = 'derivez';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code     => 'MaximumTransfers',
        message_params => [0],
        rule           => $rule_name
        },
        'expected error when limit is hit - total limits not applied on derivez';
};

subtest 'rule transfers.daily_total_amount_limit' => sub {
    my $rule_name = 'transfers.daily_total_amount_limit';

    my $client_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $client_1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $user = BOM::User->create(
        email    => 'test+daily_amount@test.deriv',
        password => 'TRADING PASS',
    );
    $user->add_client($client_2);
    $user->add_client($client_1);
    $client_1->account('USD');
    $client_2->account('EUR');
    my $rule_engine_1 = BOM::Rules::Engine->new(client => $client_1);
    my $rule_engine_2 = BOM::Rules::Engine->new(client => $client_2);
    my $params        = {
        loginid           => $client_1->loginid,
        platform          => 'derivez',
        amount            => 500,
        platform_currency => 'USD'
    };

    ok $rule_engine_1->apply_rules($rule_name, %$params), 'The test by-passed for derivez USD';

    $params->{platform} = 'dxtrade';

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(0);
    ok $rule_engine_1->apply_rules($rule_name, %$params), 'The test by-passed if total limit is disabled';

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);
    my $user_daily_transfer_amount =
        BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->daily_cumulative_limit->dxtrade(1000);

    ok $rule_engine_1->apply_rules($rule_name, %$params), 'The test passed';
    $client_1->user->daily_transfer_incr({
        type   => 'dxtrade',
        amount => 500
    });
    $params->{amount} = 1000;
    is_deeply exception { $rule_engine_1->apply_rules($rule_name, %$params) },
        {
        error_code     => 'MaximumAmountTransfers',
        message_params => [$user_daily_transfer_amount, 'USD'],
        rule           => $rule_name
        },
        'expected error when limit is hit';
    $user_daily_transfer_amount =
        BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->daily_cumulative_limit->dxtrade(2000);
    $params = {
        loginid           => $client_2->loginid,
        platform          => 'dxtrade',
        amount            => 500,
        platform_currency => 'EUR'
    };
    $redis->hmset(
        'exchange_rates::USD_EUR',
        quote => 0.5,
        epoch => time
    );
    ok $rule_engine_2->apply_rules($rule_name, %$params), 'The test by-passed for derivez EUR';

    $client_2->user->daily_transfer_incr({
        type   => 'dxtrade',
        amount => 500
    });
    $params->{amount} = 1000;
    is_deeply exception { $rule_engine_2->apply_rules($rule_name, %$params) },
        {
        error_code     => 'MaximumAmountTransfers',
        message_params => [$user_daily_transfer_amount, 'USD'],
        rule           => $rule_name
        },
        'expected error when limit is hit';
};

subtest 'rule transfers.limits' => sub {
    my $rule_name = 'transfers.limits';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $user = BOM::User->create(
        email    => 'test+limits@test.deriv',
        password => 'TRADING PASS',
    );
    $user->add_client($client);
    $client->account('USD');

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    my $params      = {
        loginid           => $client->loginid,
        platform          => 'dxtrade',
        platform_currency => 'USD',
    };

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'InvalidAction',
        rule       => $rule_name
        },
        'expected error when no action given';

    $params->{action} = 'walk the dog';

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'InvalidAction',
        rule       => $rule_name
        },
        'expected error when invalid action given';

    subtest 'Deposit' => sub {
        $params->{action} = 'deposit';

        my $app_config = BOM::Config::Runtime->instance->app_config();
        $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
        $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":10}}'});

        $params->{amount} = 1;
        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code     => 'InvalidMinAmount',
            message_params => [formatnumber('amount', 'USD', 10), 'USD'],
            rule           => $rule_name
            },
            'expected error when amount is less than minimum';

        $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":1}}'});
        $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":20}}'});

        $params->{amount} = 30;
        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code     => 'InvalidMaxAmount',
            message_params => [formatnumber('amount', 'USD', 20), 'USD'],
            rule           => $rule_name
            },
            'expected error when amount is larger than maximum';

        $params->{amount} = 20;
        $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":20}}'});
        ok $rule_engine->apply_rules($rule_name, %$params), 'The test passes';

        subtest 'Crypto' => sub {
            my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });
            $user->add_client($client);
            $client->account('BTC');
            $client->save;

            $rule_engine = BOM::Rules::Engine->new(client => $client);

            $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"BTC","amount":0.01}}'});
            $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"BTC","amount":1}}'});
            $params->{amount}  = 0.0099;
            $params->{loginid} = $client->loginid;

            is_deeply exception { $rule_engine->apply_rules($rule_name, %$params); },
                {
                error_code     => 'InvalidMinAmount',
                message_params => [formatnumber('amount', 'BTC', 0.01), 'BTC'],
                rule           => $rule_name
                },
                'min limit hit';

            $params->{amount} = 2;
            is_deeply exception { $rule_engine->apply_rules($rule_name, %$params); },
                {
                error_code     => 'InvalidMaxAmount',
                message_params => [formatnumber('amount', 'BTC', 1), 'BTC'],
                rule           => $rule_name
                },
                'max limit hit';

            $params->{amount} = 0.02;
            ok $rule_engine->apply_rules($rule_name, %$params), 'The test passes';
        };
    };

    subtest 'Withdrawal' => sub {
        $params->{action} = 'withdrawal';

        my $app_config = BOM::Config::Runtime->instance->app_config();
        $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
        $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":10}}'});

        $params->{amount} = 1;
        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code     => 'InvalidMinAmount',
            message_params => [formatnumber('amount', 'USD', 10), 'USD'],
            rule           => $rule_name
            },
            'expected error when amount is less than minimum';

        $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":1}}'});
        $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":20}}'});

        $params->{amount} = 30;
        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code     => 'InvalidMaxAmount',
            message_params => [formatnumber('amount', 'USD', 20), 'USD'],
            rule           => $rule_name
            },
            'expected error when amount is larger than maximum';

        $params->{amount} = 20;
        $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":20}}'});
        ok $rule_engine->apply_rules($rule_name, %$params), 'The test passes';

        subtest 'Crypto' => sub {
            my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });
            $user->add_client($client);
            $client->account('BTC');

            $rule_engine = BOM::Rules::Engine->new(client => $client);
            $params->{loginid} = $client->loginid;

            $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":20}}'});
            ok $rule_engine->apply_rules($rule_name, %$params), 'The test passes';
        };
    };
};

subtest 'rule transfers.experimental_currency_email_whitelisted' => sub {
    my $email  = 'test+experimental@test.deriv';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $user = BOM::User->create(
        email    => $email,
        password => 'TRADING PASS',
    );
    $user->add_client($client);
    $client->account('BTC');
    $client->email($email);
    $client->save;

    my $rule_name   = 'transfers.experimental_currency_email_whitelisted';
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    # Mock for config
    my $currency_config_mock  = Test::MockModule->new('BOM::Config::CurrencyConfig');
    my $experimental_currency = 'USD';

    $currency_config_mock->mock('is_experimental_currency', sub { shift eq $experimental_currency });

    my $params = {
        loginid           => $client->loginid,
        platform_currency => 'USD'
    };

    BOM::Config::Runtime->instance->app_config->payments->experimental_currencies_allowed([]);
    $params->{platform_currency} = 'USD';

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'CurrencyTypeNotAllowed',
        rule       => $rule_name
        },
        'Expected error when platform account currency is experimental and email is not whitelisted';

    $experimental_currency = 'BTC';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'CurrencyTypeNotAllowed',
        rule       => $rule_name
        },
        'Expected error when local account currency is experimental and email is not whitelisted';

    $experimental_currency = 'GBP';
    lives_ok { $rule_engine->apply_rules($rule_name, %$params) } 'Test passes when currency is not experimental';

    BOM::Config::Runtime->instance->app_config->payments->experimental_currencies_allowed([$email]);
    $experimental_currency = 'USD';

    lives_ok { $rule_engine->apply_rules($rule_name, %$params) } 'Test passes when currency is experimental and email is whitelisted';
};

my $rule_name = 'transfers.landing_companies_are_the_same';
subtest $rule_name => sub {
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => "$rule_name\@test.deriv",
        password => 'Test pass',
    );
    $user->add_client($client_vr);
    $user->add_client($client_cr);

    my $rule_engine    = BOM::Rules::Engine->new(client => [$client_cr, $client_vr]);
    my $expected_error = {
        error_code => 'DifferentLandingCompanies',
        rule       => $rule_name
    };

    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid_from => $client_vr->loginid, loginid_to => $client_cr->loginid) },
        $expected_error,
        'Correct error when transfering between different  landing companies - VR to CR';

    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid_from => $client_cr->loginid, loginid_to => $client_vr->loginid) },
        $expected_error,
        'Correct error when transfering between different  landing companies - CR to VR';

    lives_ok { $rule_engine->apply_rules($rule_name, loginid_from => $client_cr->loginid, loginid_to => $client_cr->loginid) }
    'No error for CR to CR';
    lives_ok { $rule_engine->apply_rules($rule_name, loginid_from => $client_vr->loginid, loginid_to => $client_vr->loginid) }
    'No error for VR to VR';
};

subtest 'rule transfers.real_to_virtual_not_allowed' => sub {
    my $rule_name = 'transfers.real_to_virtual_not_allowed';

    my $client_to = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $user = BOM::User->create(
        email    => 'test+real+virtual@test.deriv',
        password => 'TRADING PASS',
    );
    $user->add_client($client_to);
    $client_to->account('USD');

    my $client_from = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $user->add_client($client_from);
    $client_from->account('USD');

    my $params = {
        loginid_to   => $client_to->loginid,
        loginid_from => $client_from->loginid,
    };
    my $rule_engine = BOM::Rules::Engine->new(client => [$client_to, $client_from]);
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'RealToVirtualNotAllowed',
        rule       => $rule_name
        },
        'invalid transfer from virtual to real';

    my $client_to_1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    $user->add_client($client_to_1);
    $client_to_1->account('USD');

    $rule_engine = BOM::Rules::Engine->new(client => [$client_to, $client_to_1]);
    $params      = {
        loginid      => $client_to->loginid,
        loginid_to   => $client_to->loginid,
        loginid_from => $client_to_1->loginid,
    };

    ok $rule_engine->apply_rules($rule_name, %$params), 'no error when both are virtual';
};

subtest 'rule transfers.authorized_client_should_be_real' => sub {
    my $rule_name = 'transfers.authorized_client_should_be_real';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'test+real+real@test.deriv',
        password => 'TRADING PASS',
    );
    $user->add_client($client);
    $client->account('USD');

    my $client_from = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $user->add_client($client_from);
    $client_from->account('BTC');
    my $params = {
        loginid      => $client->loginid,
        loginid_from => $client_from->loginid,
        token_type   => 'oauth_token'
    };
    my $rule_engine = BOM::Rules::Engine->new(client => [$client, $client_from]);

    ok $rule_engine->apply_rules($rule_name, %$params), 'no error when both are real';

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    $rule_engine = BOM::Rules::Engine->new(client => [$client, $client_from]);

    $params = {
        loginid      => $client->loginid,
        loginid_from => $client_from->loginid,
        token_type   => 'not_oauth_token'
    };

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'AuthorizedClientIsVirtual',
        rule       => $rule_name
        },
        'token type is not equal to oauth_token';

    $params = {
        loginid      => $client->loginid,
        loginid_from => $client_from->loginid,
        token_type   => 'oauth_token'
    };

    ok $rule_engine->apply_rules($rule_name, %$params), 'no error when not authorized';
};

subtest 'rule transfers.same_account_not_allowed' => sub {
    my $rule_name = 'transfers.same_account_not_allowed';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'same+account@test.deriv',
        password => 'TRADING PASS',
    );
    $user->add_client($client);
    $client->account('USD');

    my $params = {
        loginid_to   => $client->loginid,
        loginid_from => $client->loginid,
    };
    my $rule_engine = BOM::Rules::Engine->new(client => [$client]);

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'SameAccountNotAllowed',
        rule       => $rule_name
        },
        'Transfer to the same account is not allowed';

    my $client_to = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $user->add_client($client_to);
    $client_to->account('BTC');

    $params = {
        loginid_to   => $client_to->loginid,
        loginid_from => $client->loginid,
    };
    ok $rule_engine->apply_rules($rule_name, %$params), 'no error when they are different';
};

subtest 'rule transfers.wallet_accounts_not_allowed' => sub {
    my $rule_name = 'transfers.wallet_accounts_not_allowed';
    my $user      = BOM::User->create(
        email    => 'wallet_not_allowed@test.deriv',
        password => 'TRADING PASS',
    );
    my $wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CRW',
            email       => 'wallet_not_allowed@test.deriv',

    });
    $user->add_client($wallet);

    my $params = {
        loginid_to   => $wallet->loginid,
        loginid_from => $wallet->loginid,
    };
    my $rule_engine = BOM::Rules::Engine->new(client => [$wallet]);

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'WalletAccountsNotAllowed',
        rule       => $rule_name
        },
        'Transfer between wallet accounts is not allowed';

    my $client_1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $user->add_client($client_1);
    $rule_engine = BOM::Rules::Engine->new(client => [$wallet, $client_1]);
    $params      = {
        loginid_to   => $client_1->loginid,
        loginid_from => $wallet->loginid,
    };
    ok $rule_engine->apply_rules($rule_name, %$params), 'transfer bewteen account and wallet is allowed';
};

subtest 'rule transfers.client_loginid_client_from_loginid_mismatch' => sub {
    my $rule_name = 'transfers.client_loginid_client_from_loginid_mismatch';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'same+account+from@test.deriv',
        password => 'TRADING PASS',
    );
    $client->account('USD');
    $user->add_client($client);

    my $client_from = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $client_from->account('BTC');

    $user->add_client($client_from);

    my $params = {
        loginid      => $client_from->loginid,
        loginid_from => $client->loginid,
        token_type   => 'not_oauth_token'
    };

    my $rule_engine = BOM::Rules::Engine->new(client => [$client, $client_from]);

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'IncompatibleClientLoginidClientFrom',
        rule       => $rule_name
        },
        "You can only transfer from the current authorized client's account.";

    $params = {
        loginid      => $client_from->loginid,
        loginid_from => $client->loginid,
        token_type   => 'oauth_token'
    };
    ok $rule_engine->apply_rules($rule_name, %$params), 'no error when client is authenticated';

    $params = {
        loginid      => $client->loginid,
        loginid_from => $client->loginid,
        token_type   => 'not_oauth_token'
    };

    $rule_engine = BOM::Rules::Engine->new(client => [$client]);
    ok $rule_engine->apply_rules($rule_name, %$params), 'no error when client and client from are equal';
};

subtest 'rule transfers.same_landing_companies' => sub {
    my $rule_name = 'transfers.same_landing_companies';

    my $client_to = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'landing+wallet@test.deriv',
        password => 'TRADING PASS',
    );
    $client_to->account('USD');
    $user->add_client($client_to);

    my $client_from = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $client_from->account('BTC');

    $user->add_client($client_from);

    my $params = {
        loginid_to   => $client_from->loginid,
        loginid_from => $client_to->loginid
    };

    my $rule_engine = BOM::Rules::Engine->new(client => [$client_to, $client_from]);

    ok $rule_engine->apply_rules($rule_name, %$params), 'no error when same landing company';

    my $client_from_MX = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
    });

    $client_from_MX->account('USD');
    $user->add_client($client_from_MX);

    $params = {
        loginid_to   => $client_from_MX->loginid,
        loginid_from => $client_to->loginid
    };

    $rule_engine = BOM::Rules::Engine->new(client => [$client_to, $client_from_MX]);

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'IncompatibleLandingCompanies',
        rule       => $rule_name
        },
        "Landing companies are not the same.";

    my $client_from_MLT = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });
    $client_from_MLT->account('GBP');
    $user->add_client($client_from_MLT);

    my $client_from_MF = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });

    $client_from_MF->account('EUR');
    $user->add_client($client_from_MF);

    $rule_engine = BOM::Rules::Engine->new(client => [$client_from_MF, $client_from_MLT]);

    $params = {
        loginid_to   => $client_from_MF->loginid,
        loginid_from => $client_from_MLT->loginid
    };

    ok $rule_engine->apply_rules($rule_name, %$params), 'Landing companies are malta|maltainvest.';

    my $wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CRW',
            email       => 'wallet_not_allowed@test.deriv',

    });
    $user->add_client($wallet);
    $user->add_client($client_to);
    $rule_engine = BOM::Rules::Engine->new(client => [$client_to, $wallet]);
    $params      = {
        loginid_to   => $client_to->loginid,
        loginid_from => $wallet->loginid,
    };
    ok $rule_engine->apply_rules($rule_name, %$params), 'one account is wallet';
};

$rule_name = 'transfers.no_different_fiat_currencies';
subtest $rule_name => sub {
    my %clients = map {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $client->account($_);
        ($_ => $client);
    } (qw/USD EUR BTC ETH/);

    my $rule_engine = BOM::Rules::Engine->new(client => [values %clients]);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Agrument loginid_from is missing/, 'Correct error for missing source loginid';

    my %args = (loginid_from => $clients{'USD'}->loginid);
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/Agrument loginid_to is missing/,
        'Correct error for missing receiving loginid';

    $args{loginid_to} = $clients{'EUR'}->loginid;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        rule       => $rule_name,
        error_code => 'DifferentFiatCurrencies'
        },
        'Transfer between fiat accounts is not allowed';

    for my $to_currency (qw(USD BTC ETH)) {
        $args{loginid_to} = $clients{$to_currency}->loginid;
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } "Transfer between USD and $to_currency is allowed";
    }
    $args{loginid_from} = $clients{'BTC'}->loginid;
    for my $to_currency (qw(USD EUR BTC ETH)) {
        $args{loginid_to} = $clients{$to_currency}->loginid;
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } "Transfer between BTC and $to_currency is allowed";
    }
};

$rule_name = 'transfers.crypto_exchange_rates_availability';
subtest $rule_name => sub {
    my %clients = map {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $client->account($_);
        ($_ => $client);
    } (qw/USD EUR BTC ETH/);

    my $rule_engine = BOM::Rules::Engine->new(client => [values %clients]);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Agrument loginid_from is missing/, 'Correct error for missing source loginid';

    my %args = (loginid_from => $clients{'USD'}->loginid);
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/Agrument loginid_to is missing/,
        'Correct error for missing receiving loginid';

    my $mock_currency_converter = Test::MockModule->new('ExchangeRates::CurrencyConverter');

    $args{loginid_from} = $clients{'USD'}->loginid;
    $args{loginid_to}   = $clients{'USD'}->loginid;

    $mock_currency_converter->redefine(offer_to_clients => 0);
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } "Exchange rates are not necessary for fiat currencies - USD";

    $args{loginid_to} = $clients{'EUR'}->loginid;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } "Exchange rates are not necessary for fiat currencies - EUR";

    $args{loginid_to} = $clients{'BTC'}->loginid;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        rule       => $rule_name,
        error_code => 'ExchangeRatesUnavailable',
        params     => 'BTC'
        },
        'Fiat to crypto transfer fails without exchange rates - BTC';

    $args{loginid_from} = $clients{'BTC'}->loginid;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } "Exchange rates are not necessary for same currency crypto transfers - BTC";

    $args{loginid_from} = $clients{'ETH'}->loginid;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        rule       => $rule_name,
        error_code => 'ExchangeRatesUnavailable',
        params     => 'ETH'
        },
        'Crypto to crypto transfer fails without exchange rates - ETH BTC';

    $mock_currency_converter->redefine(offer_to_clients => 1);
    $rule_engine->apply_rules($rule_name, %args);
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } "Tests passes if exchange rates are available";

    $mock_currency_converter->unmock_all;
};

$rule_name = 'transfers.clients_are_not_transfer_blocked';
subtest $rule_name => sub {
    my %clients = map {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $client->account($_);
        ($_ => $client);
    } (qw/USD EUR BTC ETH/);

    my $rule_engine = BOM::Rules::Engine->new(client => [values %clients]);
    like exception { $rule_engine->apply_rules($rule_name) }, qr/Agrument loginid_from is missing/, 'Correct error for missing source loginid';

    my %args = (loginid_from => $clients{'USD'}->loginid);
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/Agrument loginid_to is missing/,
        'Correct error for missing receiving loginid';

    my @test_cases = ({
            currency => ['USD', 'USD'],
            blocked  => [1,     1],
            pass     => 1,
            message  => 'Same curency with blocked clients is OK'
        },
        {
            currency => ['USD', 'EUR'],
            blocked  => [1,     1],
            pass     => 1,
            message  => 'Fiat curencies with blocked clients is OK'
        },
        {
            currency => ['BTC', 'ETH'],
            blocked  => [1,     1],
            pass     => 1,
            message  => 'Crypto curencies with blocked clients is OK'
        },
        {
            currency => ['BTC', 'USD'],
            blocked  => [1,     1],
            pass     => 0,
            message  => 'Crypto-fiat with blocked clients will fail'
        },
        {
            currency => ['BTC', 'USD'],
            blocked  => [1,     0],
            pass     => 0,
            message  => 'Crypto-fiat with from-client blocked will fail'
        },
        {
            currency => ['BTC', 'USD'],
            blocked  => [0,     1],
            pass     => 0,
            message  => 'Crypto-fiat with to-client blocked will fail'
        },
        {
            currency => ['BTC', 'USD'],
            blocked  => [0,     0],
            pass     => 1,
            message  => 'Crypto-fiat with no client blocked will pass'
        },
    );

    for my $test_case (@test_cases) {
        my @test_clients = map { $clients{$_} } $test_case->{currency}->@*;
        @args{qw/loginid_from loginid_to/} = map { $_->loginid } @test_clients;

        for (0, 1) {
            $test_case->{blocked}->[$_]
                ? $test_clients[$_]->status->setnx('transfers_blocked', 'test', 'test')
                : $test_clients[$_]->status->clear_transfers_blocked;
        }
        $rule_engine = BOM::Rules::Engine->new(client => \@test_clients);

        if ($test_case->{pass}) {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } $test_case->{message};
        } else {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                {
                rule       => $rule_name,
                error_code => 'TransferBlocked',
                },
                $test_case->{message};
        }
    }
};

subtest 'rule transfers.account_types_are_compatible' => sub {

    my $email  = 'test+2@test.deriv';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    my $user = BOM::User->create(
        email    => $email,
        password => 'TRADING PASS',
    );
    $user->add_client($client);
    $client->account('USD');

    my $client_from = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    $user->add_client($client_from);
    $client_from->account('USD');

    my $client_to = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    $user->add_client($client_to);
    $client_to->account('USD');

    my $rule_engine = BOM::Rules::Engine->new(client => [$client, $client_from // (), $client_to // ()]);
    my %args        = (
        loginid           => $client->loginid,
        account_type_from => 'dxtrade',
        account_type_to   => 'mt5',
    );
    my $rule_name = 'transfers.account_types_are_compatible';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'IncompatibleDxtradeToMt5',
        rule       => $rule_name
        },
        'Expected error when client_from is dxtrade and client_to is mt5';

    %args = (
        loginid           => $client->loginid,
        account_type_from => 'mt5',
        account_type_to   => 'dxtrade',
    );

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'IncompatibleMt5ToDxtrade',
        rule       => $rule_name
        },
        'Expected error when client_from is mt5 and client_to is dxtrade';

    %args = (
        loginid           => $client->loginid,
        account_type_from => 'mt5',
        account_type_to   => 'mt5',
    );

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'IncompatibleMt5ToMt5',
        rule       => $rule_name
        },
        'Expected error when client_from is mt5 and client_to is mt5';

    %args = (
        loginid           => $client->loginid,
        account_type_from => 'dxtrade',
        account_type_to   => 'dxtrade',
    );

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'IncompatibleDxtradeToDxtrade',
        rule       => $rule_name
        },
        'Expected error when client_from is dxtrade and client_to is dxtrade';

    %args = (
        loginid           => $client->loginid,
        account_type_from => 'derivez',
        account_type_to   => 'mt5',
    );

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'IncompatibleDerivezToMt5',
        rule       => $rule_name
        },
        'Expected error when client_from is derivez and client_to is mt5';

    %args = (
        loginid           => $client->loginid,
        account_type_from => 'mt5',
        account_type_to   => 'derivez',
    );

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'IncompatibleMt5ToDerivez',
        rule       => $rule_name
        },
        'Expected error when client_from is mt5 and client_to is derivez';
};

done_testing();
