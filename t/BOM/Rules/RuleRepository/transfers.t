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
        platform_currency => 'USD',
        action            => 'relax'
    };

    ok $rule_engine->apply_rules($rule_name, $params), 'no error when no currency passed';

    $params->{currency} = 'USD';
    is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
        {
        code => 'InvalidAction',
        },
        'invalid action reported';

    $params->{action} = 'deposit';
    is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
        {
        code => 'CurrencyShouldMatch',
        },
        'expected error when currency mismatch';

    $params->{currency} = 'GBP';
    ok $rule_engine->apply_rules($rule_name, $params), 'The test passes';

    $params->{action} = 'withdrawal';
    is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
        {
        code => 'CurrencyShouldMatch',
        },
        'expected error when currency mismatch';

    $params->{currency} = 'USD';
    ok $rule_engine->apply_rules($rule_name, $params), 'The test passes';
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
    my $params      = {platform => 'dxtrade'};

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade(1);
    $client->user->daily_transfer_incr('dxtrade');

    is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
        {
        code           => 'MaximumTransfers',
        message_params => [1],
        },
        'expected error when limit is hit';

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade(100);
    ok $rule_engine->apply_rules($rule_name, $params), 'The test passes';
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
        platform          => 'dxtrade',
        platform_currency => 'USD',
    };

    is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
        {
        code => 'InvalidAction',
        },
        'expected error when no action given';

    $params->{action} = 'walk the dog';

    is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
        {
        code => 'InvalidAction',
        },
        'expected error when invalid action given';

    subtest 'Deposit' => sub {
        $params->{action} = 'deposit';

        my $app_config = BOM::Config::Runtime->instance->app_config();
        $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
        $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":10}}'});

        $params->{amount} = 1;
        is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
            {
            code           => 'InvalidMinAmount',
            message_params => [formatnumber('amount', 'USD', 10), 'USD']
            },
            'expected error when amount is less than minimum';

        $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":1}}'});
        $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":20}}'});

        $params->{amount} = 30;
        is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
            {
            code           => 'InvalidMaxAmount',
            message_params => [formatnumber('amount', 'USD', 20), 'USD']
            },
            'expected error when amount is larger than maximum';

        $params->{amount} = 20;
        $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":20}}'});
        ok $rule_engine->apply_rules($rule_name, $params), 'The test passes';

        subtest 'Crypto' => sub {
            my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });
            $user->add_client($client);
            $client->account('BTC');

            my $rule_engine = BOM::Rules::Engine->new(client => $client);

            $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"BTC","amount":0.01}}'});
            $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"BTC","amount":1}}'});
            $params->{amount} = 0.0099;

            is_deeply exception { $rule_engine->apply_rules($rule_name, $params); },
                {
                code           => 'InvalidMinAmount',
                message_params => [formatnumber('amount', 'BTC', 0.01), 'BTC']
                },
                'min limit hit';

            $params->{amount} = 2;
            is_deeply exception { $rule_engine->apply_rules($rule_name, $params); },
                {
                code           => 'InvalidMaxAmount',
                message_params => [formatnumber('amount', 'BTC', 1), 'BTC']
                },
                'max limit hit';

            $params->{amount} = 0.02;
            ok $rule_engine->apply_rules($rule_name, $params), 'The test passes';
        };
    };

    subtest 'Withdrawal' => sub {
        $params->{action} = 'withdrawal';

        my $app_config = BOM::Config::Runtime->instance->app_config();
        $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
        $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":10}}'});

        $params->{amount} = 1;
        is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
            {
            code           => 'InvalidMinAmount',
            message_params => [formatnumber('amount', 'USD', 10), 'USD']
            },
            'expected error when amount is less than minimum';

        $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":1}}'});
        $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":20}}'});

        $params->{amount} = 30;
        is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
            {
            code           => 'InvalidMaxAmount',
            message_params => [formatnumber('amount', 'USD', 20), 'USD']
            },
            'expected error when amount is larger than maximum';

        $params->{amount} = 20;
        $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":20}}'});
        ok $rule_engine->apply_rules($rule_name, $params), 'The test passes';

        subtest 'Crypto' => sub {
            my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });
            $user->add_client($client);
            $client->account('BTC');

            my $rule_engine = BOM::Rules::Engine->new(client => $client);

            $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":20}}'});
            ok $rule_engine->apply_rules($rule_name, $params), 'The test passes';
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

    my $rule_name   = 'transfers.experimental_currency_email_whitelisted';
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    # Mock for config
    my $currency_config_mock  = Test::MockModule->new('BOM::Config::CurrencyConfig');
    my $experimental_currency = 'USD';

    $currency_config_mock->mock('is_experimental_currency', sub { shift eq $experimental_currency });

    my $params = {platform_currency => 'USD'};

    BOM::Config::Runtime->instance->app_config->payments->experimental_currencies_allowed([]);
    $params->{platform_currency} = 'USD';

    is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
        {
        code => 'CurrencyTypeNotAllowed',
        },
        'Expected error when platform account currency is experimental and email is not whitelisted';

    $experimental_currency = 'BTC';
    is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
        {
        code => 'CurrencyTypeNotAllowed',
        },
        'Expected error when local account currency is experimental and email is not whitelisted';

    $experimental_currency = 'GBP';
    lives_ok { $rule_engine->apply_rules($rule_name, $params) } 'Test passes when currency is not experimental';

    BOM::Config::Runtime->instance->app_config->payments->experimental_currencies_allowed([$email]);
    $experimental_currency = 'USD';

    lives_ok { $rule_engine->apply_rules($rule_name, $params) } 'Test passes when currency is experimental and email is whitelisted';
};

done_testing();
