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

my $rule_engine = BOM::Rules::Engine->new(client => $client_cr_usd);

subtest 'rule currency.is_currency_suspended' => sub {
    my $rule_name = 'currency.is_currency_suspended';

    lives_ok { $rule_engine->apply_rules($rule_name) } 'Rule applies with empty args.';

    my $mock_currency = Test::MockModule->new('BOM::Config::CurrencyConfig');
    my $suspended     = 0;
    $mock_currency->redefine(is_crypto_currency_suspended => sub { return $suspended });

    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'GBP'}) } 'Rule applies with a fiat currency.';
    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'BTC'}) } 'Rule applies if the crypto is not suspended.';

    $suspended = 1;
    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'GBP'}) } 'Rule applies with a fiat currency when cyrpto is suspended.';
    is_deeply exception { $rule_engine->apply_rules($rule_name, {currency => 'BTC'}) },
        {
        error_code => 'CurrencySuspended',
        params     => 'BTC'
        },
        'Rule fails to apply on a suspended crypto currency.';

    $mock_currency->redefine('is_crypto_currency_suspended' => sub { die 'Dying to test!' });
    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'GBP'}) } 'Rule applies with a fiat currency even crypto check dies.';
    is_deeply exception { $rule_engine->apply_rules($rule_name, {currency => 'BTC'}) },
        {
        error_code => 'InvalidCryptoCurrency',
        params     => 'BTC'
        },
        'Rule fails to apply on a failing crypto currency.';

    $mock_currency->unmock_all;
};

subtest 'rule currency.experimental_currency' => sub {
    my $rule_name = 'currency.experimental_currency';

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
    for $case (@test_cases) {
        $mock_config->redefine(is_experimental_currency => sub { return $case->{experimental} });
        $mock_runtime->redefine(experimental_currencies_allowed => sub { return $case->{allowed_emails} });

        lives_ok { $rule_engine->apply_rules($rule_name) } 'Rule always applies if there is no currency in args.';

        if ($case->{error}) {
            is_deeply exception { $rule_engine->apply_rules($rule_name, {currency => 'BTC'}) },
                {
                error_code => $case->{error},
                },
                $case->{description};
        } else {
            lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'BTC'}) } $case->{description};
        }
    }

    $mock_config->unmock_all;
    $mock_runtime->unmock_all;
};

my $rule_name = 'currency.is_available_for_new_account';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr_usd);

    subtest 'trading  account' => sub {
        lives_ok { $rule_engine->apply_rules($rule_name) } 'Rule applies if currency arg is empty';
        my $args = {
            currency     => 'EUR',
            account_type => 'trading'
        };
        is_deeply exception { $rule_engine->apply_rules($rule_name, $args) }, {code => 'CurrencyTypeNotAllowed'}, 'Only one fiat account is allowed';

        my $mock_account = Test::MockModule->new('BOM::User::Client::Account');
        $mock_account->redefine(currency_code => sub { return 'BTC' });
        lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Rule applies if the existing account is crypto';

        $args->{currency} = 'BTC';
        is_deeply exception { $rule_engine->apply_rules($rule_name, $args) },
            {
            code   => 'DuplicateCurrency',
            params => 'BTC'
            },
            'The same currency cannot be used again';

        $args->{currency} = 'ETH';
        lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Other crypto currency is allowed';
        $mock_account->unmock_all;

        $rule_engine = BOM::Rules::Engine->new(
            client          => $client_cr_usd,
            landing_company => 'malta'
        );
        $args->{currency} = 'USD';
        lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'No problem in a diffrent landing company';
    };

    subtest 'wallet account' => sub {
        my $args = {
            account_type   => 'wallet',
            currency       => 'USD',
            payment_method => 'Skrill',
        };
        is $client_cr_usd->account->currency_code(), 'USD', 'There is a trading sibling with USD currency';

        lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Wallet with the same currency as the trading account is allowed';

        my $wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'DW'});
        $wallet->payment_method('Skrill');
        $wallet->set_default_account('USD');
        $wallet->save;
        $user->add_client($wallet);

        is_deeply exception { $rule_engine->apply_rules($rule_name, $args) },
            {
            code   => 'DuplicateWallet',
            params => 'USD'
            },
            'Duplicate wallet is detected';

        $args->{payment_method} = 'Paypal';
        lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'Currency is available with a different payment method';

        $args->{currency} = 'EUR';
        lives_ok { $rule_engine->apply_rules($rule_name, $args) } 'A different currency is accpeted';
    };
};

$rule_name = 'currency.is_available_for_change';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr_usd);
    lives_ok { $rule_engine->apply_rules($rule_name) } 'Rule applies if currency arg is empty';

    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'EUR'}) } 'Fiat currency can be changed.';

    lives_ok { $rule_engine->apply_rules($rule_name, {currency => 'LTC'}) } 'Other crypto currency is allowed';

    $rule_engine = BOM::Rules::Engine->new(client => $client_cr_btc);
    is_deeply exception { $rule_engine->apply_rules($rule_name, {currency => 'EUR'}) },
        {
        code => 'CurrencyTypeNotAllowed',
        },
        'Only one fiat trading account is allowed';
};

$rule_name = 'currency.no_mt5_existing';
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

    my $engine = BOM::Rules::Engine->new(client => $client);
    ok $engine->apply_rules($rule_name), 'Rule applies with empty args';

    ok $engine->apply_rules($rule_name, {currency => 'BTC'}), 'Rule applies with no MT5 account';

    my $mock_user = Test::MockModule->new('BOM::User');
    $mock_user->redefine(get_mt5_loginids => sub { return (1, 2); });

    is exception { $engine->apply_rules($rule_name, {currency => 'BTC'}) }, undef, 'Rule applies if client currency is not set yet';

    $client->set_default_account('USD');
    is_deeply exception { $engine->apply_rules($rule_name, {currency => 'BTC'}) },
        {code => 'MT5AccountExisting'}, 'Fails after setting account entry';

    $mock_user->unmock_all;
};

$rule_name = 'currency.no_deposit';
subtest $rule_name => sub {
    ok $rule_engine->apply_rules($rule_name), 'Rule applies with empty args - no trades';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(has_deposits => sub { return 1; });
    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {code => 'AccountWithDeposit'}, 'Fails if client has deposits';
    $mock_client->unmock_all;
};

$rule_name = 'currency.account_is_not_crypto';
subtest $rule_name => sub {
    my $engine = BOM::Rules::Engine->new(client => $client_cr_usd);
    ok $rule_engine->apply_rules($rule_name), 'Rule applies for fiat account';

    $engine = BOM::Rules::Engine->new(client => $client_cr_btc);
    is_deeply exception { $engine->apply_rules($rule_name) }, {code => 'CryptoAccount'}, 'Fails for crypto account';
};

done_testing();
