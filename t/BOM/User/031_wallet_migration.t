use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Fatal;
use Test::Warnings;

use Data::Dumper;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::MT5::User::Async;
use BOM::Rules::Engine;
use BOM::TradingPlatform;
use BOM::Test::Script::DevExperts;
use BOM::Test::Helper::MT5;
use BOM::Test::Helper::CTrader;

use BOM::User::WalletMigration;

use BOM::Config::Runtime;

plan tests => 9;

BOM::Test::Helper::MT5::mock_server();
BOM::Test::Helper::CTrader::mock_server();

subtest 'Constructor: new' => sub {
    my ($user) = create_user();

    my $client_real = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $err = exception { BOM::User::WalletMigration->new() };
    like($err, qr/Required parameter 'user' is missing/, 'Should throw exception if user id is not provided');

    $err = exception { BOM::User::WalletMigration->new(user_id => 12345) };
    like($err, qr/Required parameter 'user' is missing/, 'Should throw exception if user id is invalid');

    $err = exception { my $migration = BOM::User::WalletMigration->new(user => $user) };
    like($err, qr/Required parameter 'app_id' is missing/, 'Should throw exception if app id is missed');

    $err = exception { my $migration = BOM::User::WalletMigration->new(user => $user, app_id => 'INVALID_APP_ID') };
    like($err, qr/Required parameter 'app_id' is missing/, 'Should throw exception if app id is invalid');

    $err = exception { my $migration = BOM::User::WalletMigration->new(user => $user, app_id => 0) };
    like($err, qr/Required parameter 'app_id' is missing/, 'Should throw exception if app id is invalid');

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );
    isa_ok($migration, 'BOM::User::WalletMigration', 'Should return an instance of BOM::User::WalletMigration');
};

subtest 'State check' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);
    my ($user, $client_virtual) = create_user();

    my $migration_mock = Test::MockModule->new('BOM::User::WalletMigration');
    my $is_eligible    = 0;
    $migration_mock->mock(is_eligible => sub { $is_eligible });

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    is($migration->state, 'ineligible', 'Should return new state if no action was performed');

    my $err = exception { $migration->start() };

    is($err->{error_code}, 'UserIsNotEligibleForMigration', 'Should throw exception if client is not eligible for migration');

    $is_eligible = 1;
    is($migration->state, 'eligible', 'Should return new state if no action was performed');

    eval { $migration->start() };

    is($migration->state, 'in_progress', 'Should return new state if no action was performed');

    $migration->process();

    $migration = BOM::User::WalletMigration->new(
        user   => BOM::User->new(id => $user->id),
        app_id => 1,
    );

    is($migration->state, 'migrated', 'Should return new state if no action was performed');
};

subtest 'Eligibility check' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);

    my ($user) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    ok(!$migration->is_eligible, 'Should return false if client is not eligible for migration');

    BOM::Config::Runtime->instance->app_config->system->suspend->wallets(0);

    my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $cr_usd->set_default_account('USD');
    $user->add_client($cr_usd);

    my $countries_mock = Test::MockModule->new('Brands::Countries');
    $countries_mock->mock(
        wallet_companies_for_country => sub {
            (undef, undef, my $type) = @_;
            my %mock_data = (
                virtual => [qw(virtual)],
                real    => [qw(svg)],
            );

            return $mock_data{$type} // [];
        });

    ok($migration->is_eligible, 'Should return true if client is eligible for migration');
};

subtest 'Wallet creation' => sub {
    my ($user, $client_virtual) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    my $virtual_wallet =
        eval { $migration->create_wallet(currency => 'USD', account_type => 'virtual', landing_company => 'virtual', client => $client_virtual) }
        or fail('Virtual wallet creation should not fail');

    is($virtual_wallet->account->currency_code, 'USD',                      'Should create a virtual wallet with USD currency');
    is($virtual_wallet->account_type,           'virtual',                  'Should create a virtual wallet with virtual account type');
    is($virtual_wallet->landing_company->short, 'virtual',                  'Should create a virtual wallet with virtual landing company');
    is($virtual_wallet->residence,              $client_virtual->residence, 'Should create a virtual wallet with the same residence as client');

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $user->add_client($client_cr);

    my $doughflow_wallet =
        eval { $migration->create_wallet(currency => 'USD', account_type => 'doughflow', landing_company => 'svg', client => $client_cr) }
        or fail('Real wallet creation should not fail');

    is($doughflow_wallet->account->currency_code, 'USD',                       'Should create a DF wallet with USD currency');
    is($doughflow_wallet->account_type,           'doughflow',                 'Should create a DF wallet with doughflow account type');
    is($doughflow_wallet->landing_company->short, 'svg',                       'Should create a DF wallet with svg landing company');
    is($doughflow_wallet->residence,              $client_virtual->residence,  'Should DF a DF wallet with the same residence as client');
    is($doughflow_wallet->first_name,             $client_virtual->first_name, 'Should create a DF wallet with the same first name as client');

    my $crypto_wallet =
        eval { $migration->create_wallet(currency => 'BTC', account_type => 'crypto', landing_company => 'svg', client => $client_cr) }
        or fail('Real wallet creation should not fail');

    is($crypto_wallet->account->currency_code, 'BTC',                       'Should create a DF wallet with USD currency');
    is($crypto_wallet->account_type,           'crypto',                    'Should create a DF wallet with doughflow account type');
    is($crypto_wallet->landing_company->short, 'svg',                       'Should create a DF wallet with svg landing company');
    is($crypto_wallet->residence,              $client_virtual->residence,  'Should DF a DF wallet with the same residence as client');
    is($crypto_wallet->first_name,             $client_virtual->first_name, 'Should create a DF wallet with the same first name as client');
};

subtest 'Get existing wallets' => sub {
    my ($user, $client_virtual) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    my $virtual_wallet =
        eval { $migration->create_wallet(currency => 'USD', account_type => 'virtual', landing_company => 'virtual', client => $client_virtual) }
        or fail('Virtual wallet creation should not fail');

    my $doughflow_wallet =
        eval { $migration->create_wallet(currency => 'USD', account_type => 'doughflow', landing_company => 'svg', client => $client_virtual) }
        or fail('Virtual wallet creation should not fail');

    my $crypto_wallet =
        eval { $migration->create_wallet(currency => 'BTC', account_type => 'crypto', landing_company => 'svg', client => $client_virtual) }
        or fail('Virtual wallet creation should not fail');

    my $crypto1_wallet =
        eval { $migration->create_wallet(currency => 'ETH', account_type => 'crypto', landing_company => 'svg', client => $client_virtual) }
        or fail('Virtual wallet creation should not fail');

    my $wallets = $migration->existing_wallets();

    cmp_deeply([sort keys $wallets->%*], [qw(svg virtual)], 'Should return all created regulations');

    cmp_deeply([sort keys $wallets->{virtual}->%*], [qw(virtual)],          'Should return all created account types for virtual regulation');
    cmp_deeply([sort keys $wallets->{svg}->%*],     [qw(crypto doughflow)], 'Should return all created account types for virtual regulation');

    cmp_deeply([sort keys $wallets->{virtual}->{virtual}->%*], [qw(USD)],     'Should return all created currencies for virtual account type');
    cmp_deeply([sort keys $wallets->{svg}->{crypto}->%*],      [qw(BTC ETH)], 'Should return all created currencies for crypto account type');
    cmp_deeply([sort keys $wallets->{svg}->{doughflow}->%*],   [qw(USD)],     'Should return all created currencies for doughflow account type');

    is($wallets->{virtual}{virtual}{USD}->loginid, $virtual_wallet->loginid,   'Should return the correct virtual wallet');
    is($wallets->{svg}{doughflow}{USD}->loginid,   $doughflow_wallet->loginid, 'Should return the correct doughflow wallet');
    is($wallets->{svg}{crypto}{BTC}->loginid,      $crypto_wallet->loginid,    'Should return the correct crypto wallet');
    is($wallets->{svg}{crypto}{ETH}->loginid,      $crypto1_wallet->loginid,   'Should return the correct crypto wallet');
};

subtest wallet_params_for => sub {
    my ($user, $virtual) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    # External trading platforms
    my $real_result = +{
        account_type    => 'doughflow',
        landing_company => 'svg',
        currency        => 'USD',
    };

    my $demo_result = +{
        account_type    => 'virtual',
        landing_company => 'virtual',
        currency        => 'USD',
    };

    my %test_cases = (
        MTR123 => $real_result,
        MTD123 => $demo_result,
        DXR123 => $real_result,
        DXD123 => $demo_result,
        EZR123 => $real_result,
        EZD123 => $demo_result,
    );

    $user->add_loginid($_) for keys %test_cases;

    for my $loginid (keys %test_cases) {
        my $result;
        my $error = exception {
            $result = $migration->wallet_params_for($loginid);
        };

        cmp_deeply($error,  undef,                 'Should return no error: ' . $loginid);
        cmp_deeply($result, $test_cases{$loginid}, 'Should return the expected result: ' . $loginid);
    }

    # Internal accounts
    ($user, $virtual) = create_user();

    $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    my $res = $migration->wallet_params_for($virtual->loginid);

    is $res->{client}->loginid, $virtual->loginid, 'Correct client object is returned in result for virtual account';
    delete $res->{client};

    cmp_deeply(
        $res,
        {
            'landing_company' => 'virtual',
            'account_type'    => 'virtual',
            'currency'        => 'USD'
        },
        "Correct result is returned for virtual account"
    );

    my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $cr_usd->set_default_account('USD');
    $user->add_client($cr_usd);

    $res = $migration->wallet_params_for($cr_usd->loginid);
    is $res->{client}->loginid, $cr_usd->loginid, 'Correct client object is returned in result for CR USD account';
    delete $res->{client};

    cmp_deeply(
        $res,
        {
            'landing_company' => 'svg',
            'account_type'    => 'doughflow',
            'currency'        => 'USD'
        },
        "Correct result is returned for CR USD account"
    );

    my $cr_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $cr_eur->set_default_account('EUR');
    $user->add_client($cr_eur);

    $res = $migration->wallet_params_for($cr_eur->loginid);
    is $res->{client}->loginid, $cr_eur->loginid, 'Correct client object is returned in result for CR EUR account';
    delete $res->{client};

    cmp_deeply(
        $res,
        {
            'landing_company' => 'svg',
            'account_type'    => 'doughflow',
            'currency'        => 'EUR'
        },
        "Correct result is returned for CR EUR account"
    );

    my $cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $cr_btc->set_default_account('BTC');
    $user->add_client($cr_btc);

    $res = $migration->wallet_params_for($cr_btc->loginid);
    is $res->{client}->loginid, $cr_btc->loginid, 'Correct client object is returned in result for CR BTC account';
    delete $res->{client};

    cmp_deeply(
        $res,
        {
            'landing_company' => 'svg',
            'account_type'    => 'crypto',
            'currency'        => 'BTC'
        },
        "Correct result is returned for CR BTC account"
    );

    my $cr_eth = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $cr_eth->set_default_account('ETH');
    $user->add_client($cr_eth);

    $res = $migration->wallet_params_for($cr_eth->loginid);
    is $res->{client}->loginid, $cr_eth->loginid, 'Correct client object is returned in result for CR ETH account';
    delete $res->{client};

    cmp_deeply(
        $res,
        {
            'landing_company' => 'svg',
            'account_type'    => 'crypto',
            'currency'        => 'ETH'
        },
        "Correct result is returned for CR ETH account"
    );

    my $mf_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});
    $mf_eur->set_default_account('EUR');
    $user->add_client($mf_eur);

    $res = $migration->wallet_params_for($mf_eur->loginid);
    is $res->{client}->loginid, $mf_eur->loginid, 'Correct client object is returned in result for MF EUR account';
    delete $res->{client};

    cmp_deeply(
        $res,
        {
            'landing_company' => 'maltainvest',
            'account_type'    => 'doughflow',
            'currency'        => 'EUR'
        },
        "Correct result is returned for MF EUR account"
    );
};

subtest process_migration => sub {

    subtest 'Virtual account migration' => sub {
        my ($user, $virtual) = create_user();

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $error = exception {
            $migration->process();
        };

        is($error, undef, 'No error is thrown');
        my $account_links = $user->get_accounts_links();

        ok($account_links->{$virtual->loginid}, 'Account link is created for virtual account');

        my $wallet_id = shift($account_links->{$virtual->loginid}->@*)->{loginid};
        like $wallet_id, qr/^VRW\d+$/, 'Wallet id is generated for virtual account';
    };

    subtest 'Internal accounts Real money + Virtual' => sub {
        my ($user, $virtual) = create_user();

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_btc->set_default_account('BTC');
        $user->add_client($cr_btc);

        my $error = exception {
            $migration->process();
        };

        is($error, undef, 'No error is thrown');

        my $account_links = $user->get_accounts_links();

        ok($account_links->{$virtual->loginid}, 'Account link is created for virtual account');

        my $vr_wallet_id = shift($account_links->{$virtual->loginid}->@*)->{loginid};
        like $vr_wallet_id, qr/^VRW\d+$/, 'Wallet id is generated for virtual account';

        ok($account_links->{$cr_usd->loginid}, 'Account link is created for DF account');

        my $cr_wallet_id = shift($account_links->{$cr_usd->loginid}->@*)->{loginid};
        like $cr_wallet_id, qr/^CRW\d+$/, 'Wallet id is generated for DF account';

        ok($account_links->{$cr_btc->loginid}, 'Account link is created for crypto account');

        my $cr_btc_wallet_id = shift($account_links->{$cr_btc->loginid}->@*)->{loginid};
        like $cr_btc_wallet_id, qr/^CRW\d+$/, 'Wallet id is generated for crypto account';
    };

    subtest 'Virtual account + MT5 demo' => sub {
        my ($user, $virtual) = create_user();

        my $mt5_login = BOM::MT5::User::Async::create_user({
                group => 'demo\svg',
            })->get()->{login};

        $user->add_loginid($mt5_login, 'mt5', 'demo', 'USD', +{}, undef);

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $error = exception {
            $migration->process();
        };

        is_deeply($error, undef, 'No error is thrown');

        my $account_links = $user->get_accounts_links();

        ok($account_links->{$virtual->loginid}, 'Account link is created for virtual account');
        ok($account_links->{$mt5_login},        'Account link is created for virtual account');
        my $wallet_id = $account_links->{$virtual->loginid}[0]{loginid};
        like $wallet_id, qr/^VRW\d+$/, 'Wallet id is generated for virtual account';
        is($wallet_id, $account_links->{$mt5_login}[0]{loginid}, 'Wallet id is the same for virtual and mt5 demo');
    };

    subtest 'CR + MT5 real' => sub {
        my ($user, $virtual) = create_user();

        my $mt5_login = BOM::MT5::User::Async::create_user({
                group => 'real\svg',
            })->get()->{login};

        $user->add_loginid($mt5_login, 'mt5', 'real', 'USD', +{}, undef);

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $error = exception {
            $migration->process();
        };

        is_deeply($error, undef, 'No error is thrown');

        my $account_links = $user->get_accounts_links();

        ok($account_links->{$cr_usd->loginid}, 'Account link is created for virtual account');
        ok($account_links->{$mt5_login},       'Account link is created for virtual account');
        my $wallet_id = $account_links->{$cr_usd->loginid}[0]{loginid};
        like $wallet_id, qr/^CRW\d+$/, 'Wallet id is generated for virtual account';
        is($wallet_id, $account_links->{$mt5_login}[0]{loginid}, 'Wallet id is the same for virtual and mt5 real');
    };

    subtest 'Virtual account + dxtrade demo' => sub {
        my $dxconfig = BOM::Config::Runtime->instance->app_config->system->dxtrade;
        $dxconfig->suspend->all(0);
        $dxconfig->suspend->demo(0);

        my ($user, $virtual) = create_user();

        my $dxtrader = BOM::TradingPlatform->new(
            platform    => 'dxtrade',
            client      => $virtual,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $virtual),
        );

        my %params = (
            account_type => 'demo',
            password     => 'test',
            market_type  => 'all',
            currency     => 'USD'
        );
        my $dxtrade_id = $dxtrader->new_account(%params)->{account_id};

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $error = exception {
            $migration->process();
        };

        is_deeply($error, undef, 'No error is thrown');

        my $account_links = $user->get_accounts_links();

        ok($account_links->{$virtual->loginid}, 'Account link is created for virtual account');
        ok($account_links->{$dxtrade_id},       'Account link is created for virtual account');
        my $wallet_id = $account_links->{$virtual->loginid}[0]{loginid};
        like $wallet_id, qr/^VRW\d+$/, 'Wallet id is generated for virtual account';
        is($wallet_id, $account_links->{$dxtrade_id}[0]{loginid}, 'Wallet id is the same for virtual and dxtrade demo');
    };

    subtest 'CR + dxtrade real' => sub {
        my $dxconfig = BOM::Config::Runtime->instance->app_config->system->dxtrade;
        $dxconfig->suspend->all(0);
        $dxconfig->suspend->real(0);

        my ($user, $virtual) = create_user();

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $dxtrader = BOM::TradingPlatform->new(
            platform    => 'dxtrade',
            client      => $cr_usd,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $cr_usd),
        );

        my %params = (
            account_type => 'real',
            password     => 'test',
            market_type  => 'all',
            currency     => 'USD'
        );

        my $dxtrade_id = $dxtrader->new_account(%params)->{account_id};

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $error = exception {
            $migration->process();
        };

        is_deeply($error, undef, 'No error is thrown');

        my $account_links = $user->get_accounts_links();

        ok($account_links->{$cr_usd->loginid}, 'Account link is created for virtual account');
        ok($account_links->{$dxtrade_id},      'Account link is created for virtual account');
        my $wallet_id = $account_links->{$cr_usd->loginid}[0]{loginid};
        like $wallet_id, qr/^CRW\d+$/, 'Wallet id is generated for virtual account';
        is($wallet_id, $account_links->{$dxtrade_id}[0]{loginid}, 'Wallet id is the same for virtual and dxtrade real');
    };

    subtest 'Virtual account + DerivEZ demo' => sub {
        my ($user, $virtual) = create_user();

        my $derivez_login = BOM::MT5::User::Async::create_user({
                group => 'demo\derivez_svg',
            })->get()->{login};

        $user->add_loginid($derivez_login, 'derivez', 'demo', 'USD', +{}, undef);

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $error = exception {
            $migration->process();
        };

        is_deeply($error, undef, 'No error is thrown');

        my $account_links = $user->get_accounts_links();

        ok($account_links->{$virtual->loginid}, 'Account link is created for virtual account');
        ok($account_links->{$derivez_login},    'Account link is created for virtual account');
        my $wallet_id = $account_links->{$virtual->loginid}[0]{loginid};
        like $wallet_id, qr/^VRW\d+$/, 'Wallet id is generated for virtual account';
        is($wallet_id, $account_links->{$derivez_login}[0]{loginid}, 'Wallet id is the same for virtual and derivez demo');
    };

    subtest 'CR + DerivEZ real' => sub {
        my ($user, $virtual) = create_user();

        my $derivez_login = BOM::MT5::User::Async::create_user({
                group => 'real\derivez_svg',
            })->get()->{login};

        $user->add_loginid($derivez_login, 'derivez', 'real', 'USD', +{}, undef);

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $error = exception {
            $migration->process();
        };

        is_deeply($error, undef, 'No error is thrown');

        my $account_links = $user->get_accounts_links();

        ok($account_links->{$cr_usd->loginid}, 'Account link is created for real account');
        ok($account_links->{$derivez_login},   'Account link is created for real account');
        my $wallet_id = $account_links->{$cr_usd->loginid}[0]{loginid};
        like $wallet_id, qr/^CRW\d+$/, 'Wallet id is generated for real account';
        is($wallet_id, $account_links->{$derivez_login}[0]{loginid}, 'Wallet id is the same for real and derivez real');
    };

    subtest 'Virtual account + CTrader demo' => sub {
        my ($user, $virtual) = create_user();

        my $ctrader = BOM::TradingPlatform->new(
            platform    => 'ctrader',
            client      => $virtual,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $virtual),
        );

        my $ctrader_id = $ctrader->new_account(
            account_type => 'demo',
            password     => 'test',
            market_type  => 'all',
            currency     => 'USD'
        )->{account_id};

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $error = exception {
            $migration->process();
        };

        is($error, undef, 'No error is thrown');

        my $account_links = $user->get_accounts_links();

        ok($account_links->{$virtual->loginid}, 'Account link is created for virtual account');
        ok($account_links->{$ctrader_id},       'Account link is created for virtual account');
        my $wallet_id = $account_links->{$virtual->loginid}[0]{loginid};
        like $wallet_id, qr/^VRW\d+$/, 'Wallet id is generated for virtual account';
        is($wallet_id, $account_links->{$ctrader_id}[0]{loginid}, 'Wallet id is the same for virtual and ctrader demo');
    };

    subtest 'Virtual account + CTrader real' => sub {
        my ($user, $virtual) = create_user();

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $ctrader = BOM::TradingPlatform->new(
            platform    => 'ctrader',
            client      => $cr_usd,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $cr_usd),
        );

        my $ctrader_id = $ctrader->new_account(
            account_type => 'real',
            password     => 'test',
            market_type  => 'all',
            currency     => 'USD'
        )->{account_id};

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $error = exception {
            $migration->process();
        };

        is($error, undef, 'No error is thrown');

        my $account_links = $user->get_accounts_links();

        ok($account_links->{$virtual->loginid}, 'Account link is created for real account');
        ok($account_links->{$ctrader_id},       'Account link is created for real account');
        my $wallet_id = $account_links->{$cr_usd->loginid}[0]{loginid};
        like $wallet_id, qr/^CRW\d+$/, 'Wallet id is generated for real account';
        is($wallet_id, $account_links->{$ctrader_id}[0]{loginid}, 'Wallet id is the same for real and ctrader real');
    };

};

subtest 'Getting migration plan' => sub {
    subtest 'Virtual account' => sub {
        my ($user, $virtual) = create_user();

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $plan = $migration->plan();

        is_deeply(
            $plan,
            [
                +{
                    account_category      => 'wallet',
                    account_type          => 'virtual',
                    platform              => 'dwallet',
                    currency              => 'USD',
                    landing_company_short => 'virtual',
                    link_accounts         => [
                        +{
                            loginid          => $virtual->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        }
                    ],
                },
            ],
            'Migration plan is correct'
        );
    };

    subtest 'Internal accounts Real money + Virtual' => sub {
        my ($user, $virtual) = create_user();

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_btc->set_default_account('BTC');
        $user->add_client($cr_btc);

        my $plan = $migration->plan();

        cmp_deeply $plan, bag(
            +{
                account_category      => 'wallet',
                account_type          => 'crypto',
                platform              => 'dwallet',
                currency              => 'BTC',
                landing_company_short => 'svg',
                link_accounts         => [
                    +{
                        loginid          => $cr_btc->loginid,
                        account_category => 'trading',
                        account_type     => 'standard',
                        platform         => 'dtrade',
                    }
                ],
            },
            +{
                account_category      => 'wallet',
                account_type          => 'doughflow',
                platform              => 'dwallet',
                currency              => 'USD',
                landing_company_short => 'svg',
                link_accounts         => [
                    +{
                        loginid          => $cr_usd->loginid,
                        account_category => 'trading',
                        account_type     => 'standard',
                        platform         => 'dtrade',
                    }
                ],
            },

            +{
                account_category      => 'wallet',
                account_type          => 'virtual',
                platform              => 'dwallet',
                currency              => 'USD',
                landing_company_short => 'virtual',
                link_accounts         => [
                    +{
                        loginid          => $virtual->loginid,
                        account_category => 'trading',
                        account_type     => 'standard',
                        platform         => 'dtrade',
                    }
                ],
            },
            ),
            'Migration plan is correct';
    };

    subtest 'Virtual account + MT5 demo' => sub {
        my ($user, $virtual) = create_user();

        my $mt5_login = BOM::MT5::User::Async::create_user({
                group => 'demo\svg',
            })->get()->{login};
        $user->add_loginid($mt5_login, 'mt5', 'demo', 'USD', +{}, undef);

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );
        my $plan = $migration->plan();

        cmp_deeply(
            $plan,
            bag(
                +{
                    account_category      => 'wallet',
                    account_type          => 'virtual',
                    platform              => 'dwallet',
                    currency              => 'USD',
                    landing_company_short => 'virtual',
                    link_accounts         => bag(
                        +{
                            loginid          => $virtual->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        },
                        +{
                            loginid          => $mt5_login,
                            account_category => 'trading',
                            account_type     => 'mt5',
                            platform         => 'mt5',
                        },
                    ),
                },
            ),
            'Migration plan is correct'
        );
    };

    subtest 'MT5 real' => sub {
        my ($user, $virtual) = create_user();

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_btc->set_default_account('BTC');
        $user->add_client($cr_btc);

        my $mt5_login = BOM::MT5::User::Async::create_user({
                group => 'real\svg',
            })->get()->{login};
        $user->add_loginid($mt5_login, 'mt5', 'real', 'USD', +{}, undef);

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );
        my $plan = $migration->plan();

        cmp_deeply(
            $plan,
            bag(
                +{
                    account_category      => 'wallet',
                    account_type          => 'virtual',
                    platform              => 'dwallet',
                    currency              => 'USD',
                    landing_company_short => 'virtual',
                    link_accounts         => bag(
                        +{
                            loginid          => $virtual->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        },
                    ),
                },
                +{
                    account_category      => 'wallet',
                    account_type          => 'crypto',
                    platform              => 'dwallet',
                    currency              => 'BTC',
                    landing_company_short => 'svg',
                    link_accounts         => [
                        +{
                            loginid          => $cr_btc->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        }
                    ],
                },
                +{
                    account_category      => 'wallet',
                    account_type          => 'doughflow',
                    platform              => 'dwallet',
                    currency              => 'USD',
                    landing_company_short => 'svg',
                    link_accounts         => bag(
                        +{
                            loginid          => $cr_usd->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        },
                        +{
                            loginid          => $mt5_login,
                            account_category => 'trading',
                            account_type     => 'mt5',
                            platform         => 'mt5',
                        },
                    ),
                },
            ),
            'Migration plan is correct'
        );
    };

    subtest 'dxtrade demo' => sub {
        my $dxconfig = BOM::Config::Runtime->instance->app_config->system->dxtrade;
        $dxconfig->suspend->all(0);
        $dxconfig->suspend->demo(0);

        my ($user, $virtual) = create_user();

        my $dxtrader = BOM::TradingPlatform->new(
            platform    => 'dxtrade',
            client      => $virtual,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $virtual),
        );

        my %params = (
            account_type => 'demo',
            password     => 'test',
            market_type  => 'all',
            currency     => 'USD'
        );
        my $dxtrade_id = $dxtrader->new_account(%params)->{account_id};

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );
        my $plan = $migration->plan();

        cmp_deeply(
            $plan,
            bag(
                +{
                    account_category      => 'wallet',
                    account_type          => 'virtual',
                    platform              => 'dwallet',
                    currency              => 'USD',
                    landing_company_short => 'virtual',
                    link_accounts         => bag(
                        +{
                            loginid          => $virtual->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        },
                        +{
                            loginid          => $dxtrade_id,
                            account_category => 'trading',
                            account_type     => 'dxtrade',
                            platform         => 'dxtrade',
                        },
                    ),
                },
            ),
            'Migration plan is correct'
        );
    };

    subtest 'CR + dxtrade real' => sub {
        my $dxconfig = BOM::Config::Runtime->instance->app_config->system->dxtrade;
        $dxconfig->suspend->all(0);
        $dxconfig->suspend->real(0);

        my ($user, $virtual) = create_user();

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_btc->set_default_account('BTC');
        $user->add_client($cr_btc);

        my $dxtrader = BOM::TradingPlatform->new(
            platform    => 'dxtrade',
            client      => $cr_usd,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $cr_usd),
        );

        my %params = (
            account_type => 'real',
            password     => 'test',
            market_type  => 'all',
            currency     => 'USD'
        );

        my $dxtrade_id = $dxtrader->new_account(%params)->{account_id};

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );
        my $plan = $migration->plan();

        cmp_deeply(
            $plan,
            bag(
                +{
                    account_category      => 'wallet',
                    account_type          => 'virtual',
                    platform              => 'dwallet',
                    currency              => 'USD',
                    landing_company_short => 'virtual',
                    link_accounts         => bag(
                        +{
                            loginid          => $virtual->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        },
                    ),
                },
                +{
                    account_category      => 'wallet',
                    account_type          => 'crypto',
                    platform              => 'dwallet',
                    currency              => 'BTC',
                    landing_company_short => 'svg',
                    link_accounts         => [
                        +{
                            loginid          => $cr_btc->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        }
                    ],
                },
                +{
                    account_category      => 'wallet',
                    account_type          => 'doughflow',
                    platform              => 'dwallet',
                    currency              => 'USD',
                    landing_company_short => 'svg',
                    link_accounts         => bag(
                        +{
                            loginid          => $cr_usd->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        },
                        +{
                            loginid          => $dxtrade_id,
                            account_category => 'trading',
                            account_type     => 'dxtrade',
                            platform         => 'dxtrade',
                        },
                    ),
                },
            ),
            'Migration plan is correct'
        );
    };

    subtest 'Virtual account + DerivEZ demo' => sub {
        my ($user, $virtual) = create_user();

        my $derivez_id = BOM::MT5::User::Async::create_user({
                group => 'demo\svg_ez',
            })->get()->{login};

        $user->add_loginid($derivez_id, 'derivez', 'demo', 'USD', +{}, undef);

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );
        my $plan = $migration->plan();

        cmp_deeply(
            $plan,
            bag(
                +{
                    account_category      => 'wallet',
                    account_type          => 'virtual',
                    platform              => 'dwallet',
                    currency              => 'USD',
                    landing_company_short => 'virtual',
                    link_accounts         => bag(
                        +{
                            loginid          => $virtual->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        },
                        +{
                            loginid          => $derivez_id,
                            account_category => 'trading',
                            account_type     => 'derivez',
                            platform         => 'derivez',
                        },
                    ),
                },
            ),
            'Migration plan is correct'
        );
    };

    subtest 'CR + DerivEZ real' => sub {
        my ($user, $virtual) = create_user();

        my $derivez_login = BOM::MT5::User::Async::create_user({
                group => 'real\svg_ez',
            })->get()->{login};

        $user->add_loginid($derivez_login, 'derivez', 'real', 'USD', +{}, undef);

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_btc->set_default_account('BTC');
        $user->add_client($cr_btc);

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );
        my $plan = $migration->plan();

        cmp_deeply(
            $plan,
            bag(
                +{
                    account_category      => 'wallet',
                    account_type          => 'virtual',
                    platform              => 'dwallet',
                    currency              => 'USD',
                    landing_company_short => 'virtual',
                    link_accounts         => bag(
                        +{
                            loginid          => $virtual->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        },
                    ),
                },
                +{
                    account_category      => 'wallet',
                    account_type          => 'crypto',
                    platform              => 'dwallet',
                    currency              => 'BTC',
                    landing_company_short => 'svg',
                    link_accounts         => [
                        +{
                            loginid          => $cr_btc->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        }
                    ],
                },
                +{
                    account_category      => 'wallet',
                    account_type          => 'doughflow',
                    platform              => 'dwallet',
                    currency              => 'USD',
                    landing_company_short => 'svg',
                    link_accounts         => bag(
                        +{
                            loginid          => $cr_usd->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        },
                        +{
                            loginid          => $derivez_login,
                            account_category => 'trading',
                            account_type     => 'derivez',
                            platform         => 'derivez',
                        },
                    ),
                },
            ),
            'Migration plan is correct'
        );
    };

    subtest 'ctrader demo' => sub {
        my ($user, $virtual) = create_user();

        my $ctrader = BOM::TradingPlatform->new(
            platform    => 'ctrader',
            client      => $virtual,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $virtual),
        );

        my $ctrader_id = $ctrader->new_account(
            account_type => 'demo',
            market_type  => 'all',
            currency     => 'USD',
        )->{account_id};

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );
        my $plan = $migration->plan();

        cmp_deeply(
            $plan,
            bag(
                +{
                    account_category      => 'wallet',
                    account_type          => 'virtual',
                    platform              => 'dwallet',
                    currency              => 'USD',
                    landing_company_short => 'virtual',
                    link_accounts         => bag(
                        +{
                            loginid          => $virtual->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        },
                        +{
                            loginid          => $ctrader_id,
                            account_category => 'trading',
                            account_type     => 'ctrader',
                            platform         => 'ctrader',
                        },
                    ),
                },
            ),
            'Migration plan is correct'
        );
    };

    subtest 'CR + ctrader real' => sub {
        my ($user, $virtual) = create_user();

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_btc->set_default_account('BTC');
        $user->add_client($cr_btc);

        my $ctrader = BOM::TradingPlatform->new(
            platform    => 'ctrader',
            client      => $cr_usd,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $cr_usd),
        );

        my $ctrader_id = $ctrader->new_account(
            account_type => 'real',
            market_type  => 'all',
            currency     => 'USD',
        )->{account_id};

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );
        my $plan = $migration->plan();

        cmp_deeply(
            $plan,
            bag(
                +{
                    account_category      => 'wallet',
                    account_type          => 'virtual',
                    platform              => 'dwallet',
                    currency              => 'USD',
                    landing_company_short => 'virtual',
                    link_accounts         => bag(
                        +{
                            loginid          => $virtual->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        },
                    ),
                },
                +{
                    account_category      => 'wallet',
                    account_type          => 'crypto',
                    platform              => 'dwallet',
                    currency              => 'BTC',
                    landing_company_short => 'svg',
                    link_accounts         => [
                        +{
                            loginid          => $cr_btc->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        }
                    ],
                },
                +{
                    account_category      => 'wallet',
                    account_type          => 'doughflow',
                    platform              => 'dwallet',
                    currency              => 'USD',
                    landing_company_short => 'svg',
                    link_accounts         => bag(
                        +{
                            loginid          => $cr_usd->loginid,
                            account_category => 'trading',
                            account_type     => 'standard',
                            platform         => 'dtrade',
                        },
                        +{
                            loginid          => $ctrader_id,
                            account_category => 'trading',
                            account_type     => 'ctrader',
                            platform         => 'ctrader',
                        },
                    ),
                },
            ),
            'Migration plan is correct'
        );
    };

};

my $user_counter = 1;

sub create_user {
    my $user = BOM::User->create(
        email    => 'testuser' . $user_counter++ . '@example.com',
        password => '123',
    );

    my $client_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    $client_virtual->set_default_account('USD');

    $user->add_client($client_virtual);

    return ($user, $client_virtual);
}

done_testing();
