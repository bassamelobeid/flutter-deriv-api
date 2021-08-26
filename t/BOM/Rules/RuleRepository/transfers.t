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
    $client->user->daily_transfer_incr('dxtrade');

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code     => 'MaximumTransfers',
        message_params => [1],
        rule           => $rule_name
        },
        'expected error when limit is hit';

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade(100);
    ok $rule_engine->apply_rules($rule_name, %$params), 'The test passes';
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

done_testing();
