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
        error_code  => 'CurrencySuspended',
        params      => 'BTC',
        rule        => $rule_name,
        description => "Currency $args{currency} is suspended"
        },
        'Rule fails to apply on a suspended crypto currency.';

    $mock_currency->redefine('is_crypto_currency_suspended' => sub { die 'Dying to test!' });
    $args{currency} = 'GBP';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies with a fiat currency even crypto check dies.';
    $args{currency} = 'BTC';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code  => 'InvalidCryptoCurrency',
        params      => 'BTC',
        rule        => $rule_name,
        description => "Currency $args{currency} is invalid"
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
            error_detail   => 'Experimental currency is not allowed for client'
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
                error_code  => $case->{error},
                rule        => $rule_name,
                description => $case->{error_detail}
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
    my %args = (
        loginid      => $client_cr_usd->loginid,
        account_type => 'binary'
    );
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr_usd);

    subtest 'trading  account' => sub {
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies if currency arg is empty';
        %args = (
            %args,
            currency     => 'EUR',
            account_type => 'binary'
        );
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            error_code  => 'CurrencyTypeNotAllowed',
            rule        => $rule_name,
            description => 'Currency type is not allowed'
            },
            'Only one fiat account is allowed';

        $client_cr_usd->status->set('duplicate_account', 'test', 'test');
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Duplicate account with different currency is ignored';
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args, currency => 'USD') },
            {
            error_code  => 'DuplicateCurrency',
            params      => 'USD',
            rule        => $rule_name,
            description => 'Duplicate currency detected'
            },
            "Currency shouldnt be the same as a duplicate account's";
        $client_cr_usd->status->clear_duplicate_account;

        my $mock_account = Test::MockModule->new('BOM::User::Client::Account');
        $mock_account->redefine(currency_code => sub { return 'BTC' });
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies if the existing account is crypto';

        $args{currency} = 'BTC';
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            error_code  => 'DuplicateCurrency',
            params      => 'BTC',
            rule        => $rule_name,
            description => 'Duplicate currency detected'
            },
            'The same currency cannot be used again';

        $args{currency} = 'ETH';
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Other crypto currency is allowed';
        $mock_account->unmock_all;

        %args = (
            loginid         => $client_cr_usd->loginid,
            account_type    => 'binary',
            landing_company => 'maltainvest',
            currency        => 'USD'
        );
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'No problem in a diffrent landing company';
    };

    subtest 'wallet account' => sub {
        my %args = (
            loginid      => $client_cr_usd->loginid,
            currency     => 'USD',
            account_type => 'doughflow',
        );
        is $client_cr_usd->account->currency_code(), 'USD', 'There is a trading sibling with USD currency';

        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Wallet with the same currency as the trading account is allowed';

        my $wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW'});
        $wallet->account_type('doughflow');
        $wallet->set_default_account('USD');
        $wallet->save;
        $user->add_client($wallet);

        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            error_code  => 'DuplicateWallet',
            params      => 'USD',
            rule        => $rule_name,
            description => 'Duplicate wallet detected'
            },
            'Duplicate wallet is detected';

        $args{currency} = 'EUR';
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            error_code  => 'CurrencyTypeNotAllowed',
            rule        => $rule_name,
            description => 'Currency type is not allowed'
            },
            'Same Fiat wallet is detected';

        $args{account_type} = 'p2p';
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            error_code => 'CurrencyNotAllowed',
            rule       => $rule_name
            },
            'Only usd allowed is allowed for p2p';

        $args{currency} = 'USD';
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'USD is allowed to P2P';

        $wallet->account_type('p2p');
        $wallet->set_default_account('USD');
        $wallet->save;

        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            error_code  => 'DuplicateWallet',
            params      => 'USD',
            rule        => $rule_name,
            description => 'Duplicate wallet detected'
            },
            'Duplicate wallet is detected';
    };
};

$rule_name = 'currency.is_signup_enabled';
subtest $rule_name => sub {
    my %args = (
        loginid      => $client_cr_usd->loginid,
        account_type => 'binary'
    );
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr_usd);

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies if currency arg is empty';

    %args = (
        loginid         => $client_cr_usd->loginid,
        account_type    => 'binary',
        landing_company => 'svg',
        currency        => 'USD'
    );
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'No problem in SVG with USD';

    %args = (
        loginid         => $client_cr_usd->loginid,
        account_type    => 'binary',
        landing_company => 'svg',
        currency        => 'GBP'
    );

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'No problem in SVG with GBP';

    %args = (
        loginid         => $client_cr_usd->loginid,
        account_type    => 'binary',
        landing_company => 'malta',
        currency        => 'USD'
    );
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'No problem in malta with USD';

    %args = (
        loginid         => $client_cr_usd->loginid,
        account_type    => 'binary',
        landing_company => 'malta',
        currency        => 'GBP'
    );

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'CurrencyNotAllowed',
        rule       => $rule_name,
        params     => 'GBP'
        },
        'Fail as GBP signup disabled for malta';

    %args = (
        loginid         => $client_cr_usd->loginid,
        account_type    => 'binary',
        landing_company => 'maltainvest',
        currency        => 'USD'
    );
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'No problem in maltainvest with USD';

    %args = (
        loginid         => $client_cr_usd->loginid,
        account_type    => 'binary',
        landing_company => 'maltainvest',
        currency        => 'GBP'
    );

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'CurrencyNotAllowed',
        rule       => $rule_name,
        params     => 'GBP'
        },
        'Fail as GBP signup disabled for maltainvest';
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
        error_code  => 'CurrencyTypeNotAllowed',
        rule        => $rule_name,
        description => 'Currency type is not allowed'
        },
        'Only one fiat trading account is allowed';
    $client_cr_usd->status->set('duplicate_account', 'test', 'test');
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Duplicate account with different currency is ignored';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args, currency => 'USD') },
        {
        error_code  => 'DuplicateCurrency',
        params      => 'USD',
        rule        => $rule_name,
        description => 'Duplicate currency detected'
        },
        "Currency shouldnt be the same as a duplicate account's";
    $client_cr_usd->status->clear_duplicate_account;
    $client_cr_usd->status->clear_duplicate_account;
};

$rule_name = 'currency.is_available_for_reactivation';
subtest $rule_name => sub {
    my $client_cr_usd1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr_usd1->set_default_account('USD');
    my $client_cr_usd2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr_usd2->set_default_account('USD');

    my $client_cr_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr_eur->set_default_account('EUR');

    my $user = BOM::User->create(
        email    => 'currency_reactivation@test.deriv',
        password => 'TEST PASS',
    );

    $user->add_client($client_cr_usd1);
    $user->add_client($client_cr_usd2);

    my $rule_engine = BOM::Rules::Engine->new(client => [$client_cr_usd1, $client_cr_usd2, $client_cr_eur]);

    my %args             = (loginid => $client_cr_usd1->loginid);
    my $expected_failure = {
        error_code  => 'DuplicateCurrency',
        params      => 'USD',
        rule        => $rule_name,
        description => 'Duplicate currency detected'
    };

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) }, $expected_failure,
        'Rule fails because there are enabled siblings with the same currency';

    $user->add_client($client_cr_eur);
    $client_cr_usd2->status->set('duplicate_account', 'test', 'test');
    $expected_failure = {
        error_code  => 'CurrencyTypeNotAllowed',
        rule        => $rule_name,
        description => 'Currency type is not allowed'
    };
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) }, $expected_failure, 'Rule fails because there is an enabled fiat sibling';

    $client_cr_eur->status->set('duplicate_account', 'test', 'test');
    lives_ok { $rule_engine->apply_rules($rule_name, %args, currency => 'EUR') } 'Fiat siblings are all deactivated.';
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
    $mock_user->redefine(get_mt5_loginids => sub { ('MTR1000') });

    is exception { $rule_engine->apply_rules($rule_name, %args) }, undef, 'Rule applies if client currency is not set yet';

    $client->set_default_account('USD');
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'MT5AccountExisting',
        rule       => $rule_name
        },
        'Fails after setting account entry';

    $mock_user->redefine(get_mt5_loginids => sub { () });

    is exception { $rule_engine->apply_rules($rule_name, %args) }, undef, 'Rule applies if client only has demo account';

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
    $mock_user->redefine(get_dxtrade_loginids => sub { ('DXD1000') });

    is exception { $engine->apply_rules($rule_name, %args) }, undef, 'Rule applies if client currency is not set yet';

    $client->set_default_account('USD');
    is_deeply exception { $engine->apply_rules($rule_name, %args) },
        {
        rule       => $rule_name,
        error_code => 'DXTradeAccountExisting',
        },
        'Fails after setting account entry';

    $mock_user->redefine(get_dxtrade_loginids => sub { () });

    is exception { $engine->apply_rules($rule_name, %args) }, undef, 'Rule applies if client only has no real account';

    $mock_user->unmock_all;
};

$rule_name = 'currency.has_deposit_attempt';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr_usd);
    my %args        = (loginid => $client_cr_usd->loginid);
    ok !$client_cr_usd->status->deposit_attempt,     'Client have not attempted to deposit';
    ok $rule_engine->apply_rules($rule_name, %args), 'Rule applies with empty args - has_deposit_attempt';

    my $mock_status = Test::MockModule->new('BOM::User::Client::Status');
    $mock_status->redefine(deposit_attempt => sub { return {status => 'something_here'} });
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'DepositAttempted',
        rule       => $rule_name
        },
        'Fails if client have no_currency_chnage';
    $mock_status->unmock_all;
};

$rule_name = 'currency.no_deposit';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr_usd);
    my %args        = (loginid => $client_cr_usd->loginid);
    ok !$client_cr_usd->has_deposits,                'Client has no deposit';
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

    my $client_MF = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });

    my $client_CR = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'not+legal+currency@test.deriv',
        password => 'TRADING PASS',
    );
    $client_MF->account('AUD');
    $client_CR->account('USD');

    $user->add_client($client_MF);
    $user->add_client($client_CR);

    my $params      = {loginid => $client_MF->loginid};
    my $rule_engine = BOM::Rules::Engine->new(client => [$client_MF]);

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
