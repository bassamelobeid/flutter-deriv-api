use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

my $client_cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_cr_usd->set_default_account('USD');

my $client_cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_cr_btc->set_default_account('BTC');

my $user = BOM::User->create(
    email    => 'rules_currency@test.deriv',
    password => 'TEST PASS',
);
$user->add_client($client_cr_usd);
$user->add_client($client_cr_btc);

subtest 'rule currency.is_currency_suspended' => sub {
    my $rule_name   = 'currency.is_currency_suspended';
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr_usd);

    my %args = (loginid => $client_cr_usd->loginid);
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies with empty args.';

    my $mock_currency = Test::MockModule->new('BOM::Config::CurrencyConfig');
    my $suspended     = 0;
    $mock_currency->redefine(is_crypto_currency_suspended => sub { return $suspended });

    $args{currency} = 'GBP';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies with a fiat currency.';
    $args{currency} = 'BTC';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies if the crypto is not suspended.';

    $suspended = 1;
    $args{currency} = 'GBP';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies with a fiat currency when cyrpto is suspended.';
    $args{currency} = 'BTC';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'CurrencySuspended',
        params     => 'BTC',
        rule       => $rule_name
        },
        'Rule fails to apply on a suspended crypto currency.';

    $mock_currency->redefine('is_crypto_currency_suspended' => sub { die 'Dying to test!' });
    $args{currency} = 'GBP';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies with a fiat currency even crypto check dies.';
    $args{currency} = 'BTC';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'InvalidCryptoCurrency',
        params     => 'BTC',
        rule       => $rule_name
        },
        'Rule fails to apply on a failing crypto currency.';

    $mock_currency->unmock_all;
};

subtest 'rule currency.experimental_currency' => sub {
    my $rule_name   = 'currency.experimental_currency';
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr_usd);

    my @test_cases = ({
            experimental   => 0,
            allowed_emails => [],
            description    => 'If currency is not experimental, rule always applies.',
        },
        {
            experimental   => 1,
            allowed_emails => [],
            error          => 'ExperimentalCurrency',
            description    => 'If currency is experimental and client email is not included, rule fails.',
        },
        {
            experimental   => 1,
            allowed_emails => [$client_cr_usd->email],
            description    => 'If currency is experimental and client email is included, rule applies.',
        });

    my $case;
    my $mock_config = Test::MockModule->new('BOM::Config::CurrencyConfig');
    $mock_config->redefine(is_experimental_currency => sub { return $case->{experimental} });

    my $mock_runtime = Test::MockModule->new(ref BOM::Config::Runtime->instance->app_config->payments);
    $mock_runtime->redefine(experimental_currencies_allowed => sub { return $case->{allowed_emails} });
    my %args;
    for $case (@test_cases) {
        $mock_config->redefine(is_experimental_currency => sub { return $case->{experimental} });
        $mock_runtime->redefine(experimental_currencies_allowed => sub { return $case->{allowed_emails} });

        %args = (loginid => $client_cr_usd->loginid);
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule always applies if there is no currency in args.';

        $args{currency} = 'BTC';
        if ($case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
                {
                error_code => $case->{error},
                rule       => $rule_name
                },
                $case->{description};
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, %args) } $case->{description};
        }
    }

    $mock_config->unmock_all;
    $mock_runtime->unmock_all;
};

my $rule_name = 'currency.is_available_for_new_account';
subtest $rule_name => sub {
    my %args        = (loginid => $client_cr_usd->loginid);
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr_usd);

    subtest 'trading  account' => sub {
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies if currency arg is empty';
        %args = (
            %args,
            currency     => 'EUR',
            account_type => 'trading'
        );
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            error_code => 'CurrencyTypeNotAllowed',
            rule       => $rule_name
            },
            'Only one fiat account is allowed';

        my $mock_account = Test::MockModule->new('BOM::User::Client::Account');
        $mock_account->redefine(currency_code => sub { return 'BTC' });
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies if the existing account is crypto';

        $args{currency} = 'BTC';
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            error_code => 'DuplicateCurrency',
            params     => 'BTC',
            rule       => $rule_name
            },
            'The same currency cannot be used again';

        $args{currency} = 'ETH';
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Other crypto currency is allowed';
        $mock_account->unmock_all;

        %args = (
            loginid         => $client_cr_usd->loginid,
            landing_company => 'malta',
            currency        => 'USD'
        );
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'No problem in a diffrent landing company';
    };

    subtest 'wallet account' => sub {
        my %args = (
            loginid        => $client_cr_usd->loginid,
            account_type   => 'wallet',
            currency       => 'USD',
            payment_method => 'Skrill',
        );
        is $client_cr_usd->account->currency_code(), 'USD', 'There is a trading sibling with USD currency';

        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Wallet with the same currency as the trading account is allowed';

        my $wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'DW'});
        $wallet->payment_method('Skrill');
        $wallet->set_default_account('USD');
        $wallet->save;
        $user->add_client($wallet);

        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            error_code => 'DuplicateWallet',
            params     => 'USD',
            rule       => $rule_name
            },
            'Duplicate wallet is detected';

        $args{payment_method} = 'Paypal';
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Currency is available with a different payment method';

        $args{currency} = 'EUR';
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'A different currency is accpeted';
    };
};

$rule_name = 'currency.is_available_for_change';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => [$client_cr_usd, $client_cr_btc]);

    my %args = (loginid => $client_cr_usd->loginid);
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies if currency arg is empty';

    lives_ok { $rule_engine->apply_rules($rule_name, %args, currency => 'EUR') } 'Fiat currency can be changed.';

    lives_ok { $rule_engine->apply_rules($rule_name, %args, currency => 'LTC') } 'Other crypto currency is allowed';

    %args = (
        loginid  => $client_cr_btc->loginid,
        currency => 'EUR'
    );
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'CurrencyTypeNotAllowed',
        rule       => $rule_name
        },
        'Only one fiat trading account is allowed';
};

$rule_name = 'currency.no_real_mt5_accounts';
subtest $rule_name => sub {
    my $email  = 'rules_no_mt5@test.deriv';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email,
    });

    BOM::User->create(
        email    => $email,
        password => 'TEST PASS',
    )->add_client($client);

    my $rule_engine = BOM::Rules::Engine->new(client => [$client_cr_usd, $client]);

    my %args = (loginid => $client->loginid);

    ok $rule_engine->apply_rules($rule_name, %args), 'Rule applies with no currency';

    $args{currency} = 'BTC';
    ok $rule_engine->apply_rules($rule_name, %args), 'Rule applies with no MT5 account';

    my $mock_user = Test::MockModule->new('BOM::User');
    $mock_user->redefine(mt5_logins => sub { ('MTR1000') });

    is exception { $rule_engine->apply_rules($rule_name, %args) }, undef, 'Rule applies if client currency is not set yet';

    $client->set_default_account('USD');
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'MT5AccountExisting',
        rule       => $rule_name
        },
        'Fails after setting account entry';

    $mock_user->redefine(mt5_logins => sub { () });

    is exception { $rule_engine->apply_rules($rule_name, %args) }, undef, 'Rule applies if c    lient only has demo account';

    $mock_user->unmock_all;
};

$rule_name = 'currency.no_real_dxtrade_accounts';
subtest $rule_name => sub {
    my $email  = 'rules_no_dx@test.deriv';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email,
    });

    BOM::User->create(
        email    => $email,
        password => 'TEST PASS',
    )->add_client($client);

    my %args = (loginid => $client->loginid);

    my $engine = BOM::Rules::Engine->new(client => $client);
    ok $engine->apply_rules($rule_name, %args), 'Rule applies with no currency';

    $args{currency} = 'BTC';
    ok $engine->apply_rules($rule_name, %args), 'Rule applies with no MT5 account';

    my $mock_user = Test::MockModule->new('BOM::User');
    $mock_user->redefine(loginids => sub { ($client->loginid, 'DXD1000', 'DXR1001', 'MTR1000', 'MT1001', 'MTD1002') });

    is exception { $engine->apply_rules($rule_name, %args) }, undef, 'Rule applies if client currency is not set yet';

    $client->set_default_account('USD');
    is_deeply exception { $engine->apply_rules($rule_name, %args) }, {code => 'DXTradeAccountExisting'}, 'Fails after setting account entry';

    $mock_user->redefine(loginids => sub { ($client->loginid, 'DXD1000', 'MTR1000', 'MT1001', 'MTD1002') });

    is exception { $engine->apply_rules($rule_name, %args) }, undef, 'Rule applies if client only has demo account';

    $mock_user->unmock_all;
};

$rule_name = 'currency.no_deposit';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr_usd);
    my %args        = (loginid => $client_cr_usd->loginid);
    ok !$client_cr_usd->has_deposits, 'Client has no deposit';
    ok $rule_engine->apply_rules($rule_name, %args), 'Rule applies with empty args - no deposit';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(has_deposits => sub { return 1; });
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'AccountWithDeposit',
        rule       => $rule_name
        },
        'Fails if client has deposits';
    $mock_client->unmock_all;
};

$rule_name = 'currency.account_is_not_crypto';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => [$client_cr_usd, $client_cr_btc]);
    my %args        = (loginid => $client_cr_usd->loginid);

    ok $rule_engine->apply_rules($rule_name, %args), 'Rule applies for fiat account';

    $args{loginid} = $client_cr_btc->loginid;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'CryptoAccount',
        rule       => $rule_name
        },
        'Fails for crypto account';
};

$rule_name = 'currency.known_currencies_allowed';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => [$client_cr_usd, $client_cr_btc]);
    my %args        = (
        loginid  => $client_cr_usd->loginid,
        currency => 'USD'
    );

    ok $rule_engine->apply_rules($rule_name, %args), 'Rule applies for legal currency';

    $args{currency} = 'US';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'IncompatibleCurrencyType',
        rule       => $rule_name
        },
        'Only known currencies are allowed.';
};

subtest 'rule currency.account_currency_is_legal' => sub {
    my $rule_name = 'currency.account_currency_is_legal';

    my $client_MX = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
    });

    my $client_CR = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'not+legal+currency@test.deriv',
        password => 'TRADING PASS',
    );
    $client_MX->account('EUR');
    $client_CR->account('USD');

    $user->add_client($client_MX);
    $user->add_client($client_CR);

    my $params      = {loginid => $client_MX->loginid};
    my $rule_engine = BOM::Rules::Engine->new(client => [$client_MX]);

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'CurrencyNotLegalLandingCompany',
        rule       => $rule_name
        },
        'currency not legal';

    $params = {
        loginid => $client_CR->loginid,
    };
    $rule_engine = BOM::Rules::Engine->new(client => [$client_CR]);
    ok $rule_engine->apply_rules($rule_name, %$params), 'all currencies are legal';
};
done_testing();
