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

my $redis      = BOM::Config::Redis::redis_exchangerates_write();
my $app_config = BOM::Config::Runtime->instance->app_config;

subtest 'rule transfers.currency_should_match' => sub {
    my $rule_name = 'transfers.currency_should_match';

    my $rule_engine = BOM::Rules::Engine->new;

    is_deeply exception { $rule_engine->apply_rules($rule_name, amount_currency => 'USD', request_currency => 'IDR') },
        {
        error_code => 'CurrencyShouldMatch',
        rule       => $rule_name
        },
        'expected error when currency mismatch';

    ok $rule_engine->apply_rules(
        $rule_name,
        amount_currency  => 'USD',
        request_currency => 'USD'
        ),
        'Pass when currencies match';

    ok $rule_engine->apply_rules(
        $rule_name,
        amount_currency  => 'USD',
        request_currency => undef
        ),
        'Pass with undef request_currency';

    is_deeply exception { $rule_engine->apply_rules($rule_name, amount_currency => 'USD', request_currency => '') },
        {
        error_code => 'CurrencyShouldMatch',
        rule       => $rule_name
        },
        'expected error when empty request_currency';
};

subtest 'transfers.daily_count_limit' => sub {
    my $rule_name = 'transfers.daily_count_limit';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'test+daily@test.deriv',
        password => 'TRADING PASS',
    );
    $client->account('USD');
    $user->add_client($client);
    $user->add_loginid('DXR001', 'dxtrade', 'real', 'USD');
    $user->add_loginid('EZR001', 'derivez', 'real', 'USD');

    my $rule_engine = BOM::Rules::Engine->new(
        client => $client,
        user   => $user
    );

    my %args = (
        loginid_from    => $client->loginid,
        loginid_to      => 'DXR001',
        amount          => 10,
        amount_currency => 'USD'
    );

    $app_config->payments->transfer_between_accounts->limits->dxtrade(1);
    $app_config->payments->transfer_between_accounts->limits->derivez(1);

    $user->daily_transfer_incr(%args);

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'MaximumTransfers',
        params     => [1],
        rule       => $rule_name
        },
        'expected error when limit is hit';

    $app_config->payments->transfer_between_accounts->limits->dxtrade(100);
    ok $rule_engine->apply_rules($rule_name, %args), 'The test passes';

    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);
    ok $rule_engine->apply_rules($rule_name, %args), 'The rule is by-passed using when total limits enabled';
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(0);

    $args{loginid_to} = 'EZR001';
    is exception { $rule_engine->apply_rules($rule_name, %args) }, undef, 'derivez passes';
};

subtest 'rule transfers.daily_total_amount_limit' => sub {
    my $rule_name = 'transfers.daily_total_amount_limit';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $user = BOM::User->create(
        email    => 'test+daily_amount@test.deriv',
        password => 'TRADING PASS',
    );
    $client->account('USD');
    $user->add_client($client);
    $user->add_loginid('DXR002', 'dxtrade', 'real', 'USD');
    $user->add_loginid('EZR002', 'derivez', 'real', 'USD');
    my $rule_engine = BOM::Rules::Engine->new(
        client => $client,
        user   => $user
    );

    $app_config->payments->transfer_between_accounts->limits->dxtrade(10);
    $app_config->payments->transfer_between_accounts->limits->derivez(10);
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->dxtrade(10);
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->derivez(10);
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);

    $redis->hmset(
        'exchange_rates::USD_EUR',
        quote => 0.5,
        epoch => time
    );

    my %args = (
        loginid_from => $client->loginid,
        loginid_to   => 'DXR002'
    );
    $user->daily_transfer_incr(
        %args,
        amount          => 5,
        amount_currency => 'USD'
    );

    is exception { $rule_engine->apply_rules($rule_name, %args, amount => 5,   amount_currency => 'USD') }, undef, 'can transfer up to limit';
    is exception { $rule_engine->apply_rules($rule_name, %args, amount => 2.5, amount_currency => 'EUR') }, undef, 'can transfer EUR up to limit';

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args, amount => 6, amount_currency => 'USD') },
        {
        error_code => 'MaximumAmountTransfers',
        params     => ['10.00', 'USD'],
        rule       => $rule_name
        },
        'expected error when limit is hit';

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args, amount => 3, amount_currency => 'EUR') },
        {
        error_code => 'MaximumAmountTransfers',
        params     => ['5.00', 'EUR'],
        rule       => $rule_name
        },
        'expected error when limit is hit with EUR';

    $args{loginid_to} = 'EZR002';
    is exception { $rule_engine->apply_rules($rule_name, %args, amount => 10, amount_currency => 'USD') }, undef, 'DerivEZ can transfer up to limit';
    is exception { $rule_engine->apply_rules($rule_name, %args, amount => 5, amount_currency => 'EUR') }, undef,
        'DerivEZ can transfer EUR up to limit';

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args, amount => 10.01, amount_currency => 'USD') },
        {
        error_code => 'MaximumAmountTransfers',
        params     => ['10.00', 'USD'],
        rule       => $rule_name
        },
        'DerivEZ expected error when limit is hit';

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args, amount => 5.01, amount_currency => 'EUR') },
        {
        error_code => 'MaximumAmountTransfers',
        params     => ['5.00', 'EUR'],
        rule       => $rule_name
        },
        'DerivEZ expected error when limit is hit with EUR';

    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(0);

    is exception { $rule_engine->apply_rules($rule_name, %args, amount => 100, amount_currency => 'USD') }, undef,
        'DerivEZ can transfer over limit when cumulative limit disabled';
    is exception { $rule_engine->apply_rules($rule_name, %args, amount => 50, amount_currency => 'EUR') }, undef,
        'DerivEZ can transfer over limit when cumulative limit disabled';

    $args{loginid_to} = 'DXR002';
    is exception { $rule_engine->apply_rules($rule_name, %args, amount => 100, amount_currency => 'USD') }, undef,
        'DerivX can transfer over limit when cumulative limit disabled';
    is exception { $rule_engine->apply_rules($rule_name, %args, amount => 50, amount_currency => 'EUR') }, undef,
        'DerivEZ can transfer over limit when cumulative limit disabled';

    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->dxtrade(0);
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->derivez(0);

    is exception { $rule_engine->apply_rules($rule_name, %args, amount => 100, amount_currency => 'USD') }, undef,
        'DerivX can transfer over limit when cumulative limit is zero';
    is exception { $rule_engine->apply_rules($rule_name, %args, amount => 50, amount_currency => 'EUR') }, undef,
        'DerivX can transfer over limit when cumulative limit is zero';

    $args{loginid_to} = 'EZR002';
    is exception { $rule_engine->apply_rules($rule_name, %args, amount => 100, amount_currency => 'USD') }, undef,
        'DerivEZ can transfer over limit when cumulative limit is zero';
    is exception { $rule_engine->apply_rules($rule_name, %args, amount => 50, amount_currency => 'EUR') }, undef,
        'DerivEZ can transfer over limit when cumulative limit is zero';
};

subtest 'rule transfers.limits' => sub {
    my $rule_name = 'transfers.limits';

    $redis->hmset(
        'exchange_rates::USD_BTC',
        quote => 1 / 40000,
        epoch => time
    );

    my $rule_engine = BOM::Rules::Engine->new();
    my $app_config  = BOM::Config::Runtime->instance->app_config();
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    subtest 'USD limits' => sub {
        $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":10}}'});
        $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":100}}'});

        is_deeply exception { $rule_engine->apply_rules($rule_name, platform => 'dxtrade', amount => 9.90, amount_currency => 'USD') },
            {
            error_code => 'InvalidMinAmount',
            params     => [formatnumber('amount', 'USD', 10.00), 'USD'],
            rule       => $rule_name
            },
            'expected error when USD amount is less than minimum';

        ok $rule_engine->apply_rules(
            $rule_name,
            platform        => 'dxtrade',
            amount          => 10.00,
            amount_currency => 'USD'
            ),
            'exact USD minimum passes';

        is_deeply exception { $rule_engine->apply_rules($rule_name, platform => 'dxtrade', amount => 100.01, amount_currency => 'USD') },
            {
            error_code => 'InvalidMaxAmount',
            params     => [formatnumber('amount', 'USD', 100), 'USD'],
            rule       => $rule_name
            },
            'expected error when USD amount is larger than maximum';

        ok $rule_engine->apply_rules(
            $rule_name,
            platform        => 'dxtrade',
            amount          => 100.00,
            amount_currency => 'USD'
            ),
            'exact USD maximum passes';

        is_deeply exception { $rule_engine->apply_rules($rule_name, platform => 'dxtrade', amount => 0.00024, amount_currency => 'BTC') },
            {
            error_code => 'InvalidMinAmount',
            params     => [formatnumber('amount', 'BTC', 0.00025), 'BTC'],
            rule       => $rule_name
            },
            'expected error when BTC amount is less than minimum';

        ok $rule_engine->apply_rules(
            $rule_name,
            platform        => 'dxtrade',
            amount          => 0.00025,
            amount_currency => 'BTC'
            ),
            'exact BTC minimum passes';

        is_deeply exception { $rule_engine->apply_rules($rule_name, platform => 'dxtrade', amount => 0.00251, amount_currency => 'BTC') },
            {
            error_code => 'InvalidMaxAmount',
            params     => [formatnumber('amount', 'BTC', 0.0025), 'BTC'],
            rule       => $rule_name
            },
            'expected error when BTC amount is larger than maximum';

        ok $rule_engine->apply_rules(
            $rule_name,
            platform        => 'dxtrade',
            amount          => 0.0025,
            amount_currency => 'BTC'
            ),
            'exact BTC maximum passes';
    };

    subtest 'BTC limits' => sub {
        # 50-500 USD
        $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"BTC","amount":0.00125}}'});
        $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"BTC","amount":0.0125}}'});

        is_deeply exception { $rule_engine->apply_rules($rule_name, platform => 'dxtrade', amount => 49.99, amount_currency => 'USD') },
            {
            error_code => 'InvalidMinAmount',
            params     => [formatnumber('amount', 'USD', 50), 'USD'],
            rule       => $rule_name
            },
            'expected error when USD amount is less than minimum';

        ok $rule_engine->apply_rules(
            $rule_name,
            platform        => 'dxtrade',
            amount          => 50.00,
            amount_currency => 'USD'
            ),
            'exact USD minimum passes';

        is_deeply exception { $rule_engine->apply_rules($rule_name, platform => 'dxtrade', amount => 500.01, amount_currency => 'USD') },
            {
            error_code => 'InvalidMaxAmount',
            params     => [formatnumber('amount', 'USD', 500), 'USD'],
            rule       => $rule_name
            },
            'expected error whe USD amount is larger than maximum';

        ok $rule_engine->apply_rules(
            $rule_name,
            platform        => 'dxtrade',
            amount          => 500.00,
            amount_currency => 'USD'
            ),
            'exact USD maximum passes';

        is_deeply exception { $rule_engine->apply_rules($rule_name, platform => 'dxtrade', amount => 0.00124, amount_currency => 'BTC') },
            {
            error_code => 'InvalidMinAmount',
            params     => [formatnumber('amount', 'BTC', 0.00125), 'BTC'],
            rule       => $rule_name
            },
            'expected error when BTC amount is less than minimum';

        ok $rule_engine->apply_rules(
            $rule_name,
            platform        => 'dxtrade',
            amount          => 0.00125,
            amount_currency => 'BTC'
            ),
            'exact BTC minimum passes';

        is_deeply exception { $rule_engine->apply_rules($rule_name, platform => 'dxtrade', amount => 0.01251, amount_currency => 'BTC') },
            {
            error_code => 'InvalidMaxAmount',
            params     => [formatnumber('amount', 'BTC', 0.0125), 'BTC'],
            rule       => $rule_name
            },
            'expected error when BTC amount is larger than maximum';

        ok $rule_engine->apply_rules(
            $rule_name,
            platform        => 'dxtrade',
            amount          => 0.0125,
            amount_currency => 'BTC'
            ),
            'exact BTC maximum passes';
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
    my $rule_engine = BOM::Rules::Engine->new(
        client => [$client_to, $client_from],
        user   => $user
    );
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

    $rule_engine = BOM::Rules::Engine->new(
        client => [$client_to, $client_to_1],
        user   => $user
    );
    $params = {
        loginid      => $client_to->loginid,
        loginid_to   => $client_to->loginid,
        loginid_from => $client_to_1->loginid,
    };

    ok $rule_engine->apply_rules($rule_name, %$params), 'no error when both are virtual';
};

subtest 'rule transfers.authorized_client_is_legacy_virtual' => sub {
    my $rule_name = 'transfers.authorized_client_is_legacy_virtual';

    my %clients;
    $clients{vrtc}     = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});
    $clients{vrtc_std} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC', account_type => 'standard'});
    $clients{cr}       = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $clients{crw}      = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW', account_type => 'doughflow'});
    $clients{cr_std}   = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR',  account_type => 'standard'});

    my $rule_engine = BOM::Rules::Engine->new(client => $clients{vrtc});
    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $clients{vrtc}->loginid) },
        {
        error_code => 'TransferBlockedClientIsVirtual',
        rule       => $rule_name
        },
        'VRTC fails';

    for my $c (qw(vrtc_std cr crw cr_std)) {
        my $rule_engine = BOM::Rules::Engine->new(client => $clients{$c});
        is exception { $rule_engine->apply_rules($rule_name, loginid => $clients{$c}->loginid) }, undef, "$c passes";
    }
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

    my $client_from_MF = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });

    $client_from_MF->account('EUR');
    $user->add_client($client_from_MF);

    $params = {
        loginid_to   => $client_from_MF->loginid,
        loginid_from => $client_to->loginid
    };

    $rule_engine = BOM::Rules::Engine->new(client => [$client_to, $client_from_MF]);

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'IncompatibleLandingCompanies',
        rule       => $rule_name
        },
        "Landing companies are not the same.";

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

$rule_name = 'transfers.residence_or_country_restriction';
subtest $rule_name => sub {
    # restricted residence and citizenship with one un-restricted residence and citizenship
    for my $residence (qw(ua ru id)) {
        for my $citizen (qw(id ru ua)) {
            next if $residence eq 'id' && $citizen eq 'id';    # skip un-restricted residence and citizenship as tested below
            my $user = BOM::User->create(
                email    => "test01.$residence.$citizen" . '@gmail.com',
                password => 'abcd1234',
            );
            my $client_1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                residence   => $residence,
                citizen     => $citizen,
            });
            $user->add_client($client_1);
            $client_1->account('USD');
            my $client_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                residence   => $residence,
                citizen     => $citizen,
            });
            $user->add_client($client_2);
            $client_2->account('BTC');
            my $client_3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                residence   => $residence,
                citizen     => $citizen,
            });
            $user->add_client($client_3);
            $client_3->account('ETH');
            my $rule_engine = BOM::Rules::Engine->new(client => [$client_1, $client_2, $client_3]);
            my %args        = (
                loginid_from => $client_1->loginid,
                loginid_to   => $client_2->loginid,
            );
            # ukraine citizens are not restricted from internal transfers when residence is other than ukraine
            if ($residence eq 'id' and $citizen eq 'ua') {
                ok $rule_engine->apply_rules($rule_name, %args),
                    "Transfer from fiat to crypto is allowed for $residence residents with $citizen citizenship";
                ok $rule_engine->apply_rules($rule_name, %args),
                    "Transfer from crypto to fiat is allowed for $residence residents with $citizen citizenship";
                ok $rule_engine->apply_rules($rule_name, %args),
                    "Transfer from crypto to crypto is allowed for $residence residents with $citizen citizenship";
                next;
            }

            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                {
                rule       => $rule_name,
                error_code => 'InvalidLoginidTo',
                },
                "Correct error for $residence residents restricted from transferring from fiat to crypto with $citizen citizenship";

            %args = (
                loginid_from => $client_2->loginid,
                loginid_to   => $client_1->loginid,
            );
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                {
                rule       => $rule_name,
                error_code => 'InvalidLoginidTo',
                },
                "Correct error for $residence residents restricted from transferring from crypto to fiat with $citizen citizenship";
            %args = (
                loginid_from => $client_3->loginid,
                loginid_to   => $client_2->loginid,
            );
            ok $rule_engine->apply_rules($rule_name, %args),
                "Transfer from crypto to crypto is allowed for $residence residents with $citizen citizenship";
        }
    }

    # internal transfer for un-restricted residence and citizenship
    my $user = BOM::User->create(
        email    => 'test@test.com',
        password => 'abcd1234',
    );
    my $client_1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'id',
        citizen     => 'id',
    });
    $user->add_client($client_1);
    $client_1->account('USD');
    my $client_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'id',
        citizen     => 'id',
    });
    $user->add_client($client_2);
    $client_2->account('BTC');
    my $rule_engine = BOM::Rules::Engine->new(client => [$client_1, $client_2]);
    my %args        = (
        loginid_from => $client_1->loginid,
        loginid_to   => $client_2->loginid,
    );
    ok $rule_engine->apply_rules($rule_name, %args), "Transfer from fiat to crypto is allowed for id residents with id citizenship";

    %args = (
        loginid_from => $client_2->loginid,
        loginid_to   => $client_1->loginid,
    );
    ok $rule_engine->apply_rules($rule_name, %args), "Transfer from crypto to fiat is allowed for id residents with id citizenship";

    # Empty citizenship value should be only checked against residence

    $user = BOM::User->create(
        email    => 'test1@test.com',
        password => 'abcd1234',
    );
    $client_1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'id',
        citizen     => '',
    });
    $user->add_client($client_1);
    $client_1->account('USD');
    $client_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'id',
        citizen     => '',
    });
    $user->add_client($client_2);
    $client_2->account('BTC');
    $rule_engine = BOM::Rules::Engine->new(client => [$client_1, $client_2]);
    %args        = (
        loginid_from => $client_1->loginid,
        loginid_to   => $client_2->loginid,
    );
    ok $rule_engine->apply_rules($rule_name, %args), "Transfer from fiat to crypto is allowed for id residents with empty citizenship";

    $client_1->citizen(undef);
    $client_2->citizen(undef);

    $rule_engine = BOM::Rules::Engine->new(client => [$client_1, $client_2]);

    ok $rule_engine->apply_rules($rule_name, %args), "Transfer from fiat to crypto is allowed for id residents with citizenship undefined";

    $client_1->residence('ua');
    $client_2->residence('ua');

    $rule_engine = BOM::Rules::Engine->new(client => [$client_1, $client_2]);

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        rule       => $rule_name,
        error_code => 'InvalidLoginidTo',
        },
        'Correct error for ua residents restricted from transferring from fiat to crypto with empty citizenship';

    $client_1->residence('ru');
    $client_2->residence('ru');

    $rule_engine = BOM::Rules::Engine->new(client => [$client_1, $client_2]);

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        rule       => $rule_name,
        error_code => 'InvalidLoginidTo',
        },
        'Correct error for ru residents restricted from transferring from fiat to crypto with empty citizenship';

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
            currency          => ['USD', 'USD'],
            blocked           => [1,     1],
            transfers_blocked => {
                pass    => 1,
                message => 'Same curency with blocked clients is OK'
            },
            sibling_transfers_blocked => {
                pass    => 0,
                message => 'Same curency with blocked clients will fail'
            }
        },
        {
            currency          => ['USD', 'EUR'],
            blocked           => [1,     1],
            transfers_blocked => {
                pass    => 1,
                message => 'Fiat curencies with blocked clients is OK'
            },
            sibling_transfers_blocked => {
                pass    => 0,
                message => 'Fiat curencies with blocked clients will fail'
            }
        },
        {
            currency          => ['BTC', 'ETH'],
            blocked           => [1,     1],
            transfers_blocked => {
                pass    => 1,
                message => 'Crypto curencies with blocked clients is OK'
            },
            sibling_transfers_blocked => {
                pass    => 0,
                message => 'Crypto curencies with blocked clients will fail'
            }
        },
        {
            currency          => ['BTC', 'USD'],
            blocked           => [1,     1],
            transfers_blocked => {
                pass    => 0,
                message => 'Crypto-fiat with blocked clients will fail'
            },
            sibling_transfers_blocked => {
                pass    => 0,
                message => 'Crypto-fiat with blocked clients will fail'
            }
        },
        {
            currency          => ['BTC', 'USD'],
            blocked           => [1,     0],
            transfers_blocked => {
                pass    => 0,
                message => 'Crypto-fiat with to-client blocked will fail'
            },
            sibling_transfers_blocked => {
                pass    => 0,
                message => 'Crypto-fiat with to-client blocked will fail'
            }
        },
        {
            currency          => ['BTC', 'USD'],
            blocked           => [0,     1],
            transfers_blocked => {
                pass    => 0,
                message => 'Crypto-fiat with from-client blocked will fail'
            },
            sibling_transfers_blocked => {
                pass    => 0,
                message => 'Crypto-fiat with from-client blocked will fail'
            }
        },
        {
            currency          => ['BTC', 'USD'],
            blocked           => [0,     0],
            transfers_blocked => {
                pass    => 1,
                message => 'Crypto-fiat with no client blocked will pass'
            },
            sibling_transfers_blocked => {
                pass    => 1,
                message => 'Crypto-fiat with no client blocked will pass'
            }
        },
    );

    for my $status_to_apply (qw(transfers_blocked sibling_transfers_blocked)) {
        subtest $status_to_apply => sub {
            for my $test_case (@test_cases) {
                my @test_clients = map { $clients{$_} } $test_case->{currency}->@*;
                @args{qw/loginid_from loginid_to/} = map { $_->loginid } @test_clients;

                for (0, 1) {
                    my $method = "clear_$status_to_apply";
                    $test_case->{blocked}->[$_]
                        ? $test_clients[$_]->status->setnx($status_to_apply, 'test', 'test')
                        : $test_clients[$_]->status->$method;
                }
                $rule_engine = BOM::Rules::Engine->new(client => \@test_clients);

                if ($test_case->{$status_to_apply}->{pass}) {
                    lives_ok { $rule_engine->apply_rules($rule_name, %args) } $test_case->{$status_to_apply}->{message};
                } else {
                    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                        {
                        rule       => $rule_name,
                        error_code => 'TransferBlocked',
                        },
                        $test_case->{$status_to_apply}->{message};
                }
            }
        }
    }
};

done_testing();
