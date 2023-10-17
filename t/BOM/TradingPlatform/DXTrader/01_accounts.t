use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;
use Test::Most 0.22 (tests => 31);
use Test::Warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Script::DevExperts;
use BOM::TradingPlatform;
use BOM::Config::Runtime;
use BOM::Rules::Engine;

my $dxconfig = BOM::Config::Runtime->instance->app_config->system->dxtrade;
$dxconfig->suspend->all(0);
$dxconfig->suspend->demo(0);
$dxconfig->suspend->real(0);

$dxconfig->enable_all_market_type->demo(0);
$dxconfig->enable_all_market_type->real(0);

my $dxtrader_mock                 = Test::MockModule->new('BOM::TradingPlatform::DXTrader');
my $real_account_ids_offset       = undef;
my $real_account_ids_login_prefix = undef;

$dxtrader_mock->mock(
    'config',
    sub {
        return {
            $dxtrader_mock->original('config')->(@_)->%*,
            real_account_ids_offset       => $real_account_ids_offset,
            real_account_ids_login_prefix => $real_account_ids_login_prefix,
            real_account_ids              => 1,
        };
    });

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);

$client->account('USD');

my $dxtrader = BOM::TradingPlatform->new(
    platform    => 'dxtrade',
    client      => $client,
    rule_engine => BOM::Rules::Engine->new(client => $client),
);
isa_ok($dxtrader, 'BOM::TradingPlatform::DXTrader');

$real_account_ids_login_prefix = 'TEST';

my %params = (
    account_type => 'demo',
    password     => 'test',
    market_type  => 'all',
    currency     => 'USD'
);

$dxconfig->suspend->demo(1);
cmp_deeply(exception { $dxtrader->new_account(%params) }, {error_code => 'DXServerSuspended'}, 'cannot create demo account when demo suspended');
$dxconfig->suspend->demo(0);

$dxconfig->suspend->all(1);
cmp_deeply(exception { $dxtrader->new_account(%params) }, {error_code => 'DXSuspended'}, 'cannot create demo account when all suspended');
$dxconfig->suspend->all(0);

$dxconfig->suspend->real(1);

my $account1;
is(exception { $account1 = $dxtrader->new_account(%params) }, undef, 'can create demo account when real suspended');

cmp_deeply(
    $account1,
    {
        account_id            => 'DXD1000',
        account_type          => 'demo',
        enabled               => 1,
        balance               => num(10000),
        currency              => 'USD',
        display_balance       => '10000.00',
        login                 => re('^TEST\d+$'),
        platform              => 'dxtrade',
        market_type           => 'all',
        landing_company_short => 'svg',
    },
    'created first account'
);

cmp_deeply([$client->user->get_trading_platform_loginids('dxtrader')], bag(qw/DXD1000/), 'Correct loginids reported');

cmp_deeply([$client->user->get_trading_platform_loginids('dxtrader', 'demo')], bag(qw/DXD1000/), 'Correct loginids reported');

cmp_deeply([$client->user->get_trading_platform_loginids('dxtrader', 'real')], bag(), 'Correct loginids reported');

cmp_deeply(
    $client->user->loginid_details->{$account1->{account_id}},
    {
        loginid      => $account1->{account_id},
        platform     => 'dxtrade',
        currency     => 'USD',
        account_type => $account1->{account_type},
        status       => undef,
        attributes   => {
            clearing_code => 'default',
            client_domain => 'default',
            login         => re('^TEST\d+$'),
            account_code  => $account1->{account_id},
            market_type   => 'all',
        },
        creation_stamp => re('\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}.\d*'),
    },
    'user attributes of first account'
);

%params = (
    account_type => 'real',
    password     => 'test',
    market_type  => 'all',
    currency     => 'USD',
);

cmp_deeply(exception { $dxtrader->new_account(%params) }, {error_code => 'DXServerSuspended'}, 'cannot create real account when real suspended');

cmp_deeply($dxtrader->get_accounts(force => 1), [$account1], 'can get accounts with force param while real is suspended');

$dxconfig->suspend->real(0);

my $account2;
is(exception { $account2 = $dxtrader->new_account(%params) }, undef, 'create real account ok');

cmp_deeply(
    $account2,
    {
        account_id            => 'DXR1001',
        account_type          => 'real',
        enabled               => 1,
        balance               => num(0),
        currency              => 'USD',
        display_balance       => '0.00',
        login                 => $account1->{login},
        platform              => 'dxtrade',
        market_type           => 'all',
        landing_company_short => 'svg',
    },
    'created second account'
);

cmp_deeply([$client->user->get_trading_platform_loginids('dxtrader')], bag(qw/DXD1000 DXR1001/), 'Correct loginids reported');
cmp_deeply([$client->user->dxtrade_loginids()],                        bag(qw/DXD1000 DXR1001/), 'Correct loginids reported');

cmp_deeply([$client->user->get_trading_platform_loginids('dxtrader', 'demo')], bag(qw/DXD1000/), 'Correct loginids reported');
cmp_deeply([$client->user->dxtrade_loginids('demo')],                          bag(qw/DXD1000/), 'Correct loginids reported');

cmp_deeply([$client->user->get_trading_platform_loginids('dxtrader', 'real')], bag(qw/DXR1001/), 'Correct loginids reported');
cmp_deeply([$client->user->dxtrade_loginids('real')],                          bag(qw/DXR1001/), 'Correct loginids reported');

cmp_deeply(
    $client->user->loginid_details->{$account2->{account_id}},
    {
        loginid      => $account2->{account_id},
        platform     => 'dxtrade',
        currency     => 'USD',
        account_type => $account2->{account_type},
        status       => undef,
        attributes   => {
            login         => $account2->{login},
            clearing_code => 'default',
            client_domain => 'default',
            account_code  => $account2->{account_id},
            market_type   => 'all',
        },
        creation_stamp => re('\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}.\d*'),
    },
    'user attributes of second account'
);

$dxtrader_mock->mock(
    'get_client_accounts',
    sub {
        return [{loginid => "DXD1000"}];
    });

cmp_deeply(
    exception {
        $dxtrader->new_account(
            account_type => 'demo',
            password     => 'test',
            market_type  => 'all',
            currency     => 'USD',
        )
    },
    {
        error_code     => 'DXExistingAccount',
        message_params => [re($account1->{account_id})],
    },
    'cannot create duplicate account'
);

cmp_deeply($dxtrader->get_accounts, bag($account1, $account2), 'account list');

my $suspend_account1 = {
    account_id            => 'DXD1000',
    account_type          => 'demo',
    enabled               => 0,
    currency              => 'USD',
    login                 => $account1->{login},
    platform              => 'dxtrade',
    market_type           => 'all',
    landing_company_short => 'svg',
};

my $suspend_account2 = {
    account_id            => 'DXR1001',
    account_type          => 'real',
    enabled               => 0,
    currency              => 'USD',
    login                 => $account2->{login},
    platform              => 'dxtrade',
    market_type           => 'all',
    landing_company_short => 'svg',
};

$dxconfig->suspend->all(1);
cmp_deeply(
    $dxtrader->get_accounts,
    bag($suspend_account1, $suspend_account2),
    'User DB accounts returned instead from DerivX Server when dx all suspended'
);
$dxconfig->suspend->all(0);

$dxconfig->suspend->demo(1);
cmp_deeply($dxtrader->get_accounts, bag($account2, $suspend_account1), 'only real with enabled=1 and demo with enabled=0 when dx demo suspended');
$dxconfig->suspend->demo(0);

$dxconfig->suspend->real(1);
cmp_deeply($dxtrader->get_accounts, bag($account1, $suspend_account2), 'only demo with enabled=1 and real with enabled=0 when dx real suspended');
$dxconfig->suspend->real(0);

cmp_deeply($dxtrader->get_accounts(type => 'demo'), [$account1], 'only demo account returned for type=demo');
cmp_deeply($dxtrader->get_accounts(type => 'real'), [$account2], 'only real account returned for type=real');

subtest 'suspend user exception list' => sub {

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'tester@deriv.com'
    });

    BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);

    $client->account('USD');
    BOM::Test::Helper::Client::top_up($client, $client->currency, 10);

    my $dxtrader = BOM::TradingPlatform->new(
        platform    => 'dxtrade',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );

    $dxconfig->suspend->all(1);
    $dxconfig->suspend->demo(1);
    $dxconfig->suspend->real(1);
    $dxconfig->suspend->user_exceptions([$client->email]);

    my $account;
    is(
        exception {
            $account = $dxtrader->new_account(
                account_type => 'real',
                password     => 'test',
                market_type  => 'all',
                currency     => 'USD',
            )
        },
        undef,
        'create real account'
    );

    is(exception { $dxtrader->change_password(password => 'secret') }, undef, 'change password');

    is(
        exception {
            $account = $dxtrader->deposit(
                to_account => $account->{account_id},
                amount     => 10,
                currency   => 'USD',
            )
        },
        undef,
        'deposit'
    );

    $dxconfig->enable_all_market_type->demo(1);

    is(
        exception {
            $dxtrader->new_account(
                account_type => 'demo',
                password     => 'test',
                market_type  => 'all',
                currency     => 'USD',
            )
        },
        undef,
        'create demo account'
    );
};

subtest 'Inter landing company transfer' => sub {
    $dxconfig->suspend->all(0);
    $dxconfig->suspend->demo(0);
    $dxconfig->suspend->real(0);

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->account('USD');
    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    $client_mf->account('USD');

    my $user = BOM::User->create(
        email    => 'inter_lc@deriv.com',
        password => 'test',
    );
    $user->add_client($client_cr);
    $user->add_client($client_mf);

    BOM::Test::Helper::Client::top_up($client_cr, $client_cr->currency, 10);
    BOM::Test::Helper::Client::top_up($client_mf, $client_mf->currency, 10);

    my $dxtrader_cr = BOM::TradingPlatform->new(
        platform    => 'dxtrade',
        client      => $client_cr,
        rule_engine => BOM::Rules::Engine->new(client => $client_cr),
    );

    my $dxtrader_mf = BOM::TradingPlatform->new(
        platform    => 'dxtrade',
        client      => $client_mf,
        rule_engine => BOM::Rules::Engine->new(client => $client_mf),
    );

    my $account;
    is(
        exception {
            $account = $dxtrader_cr->new_account(
                account_type => 'real',
                password     => 'test',
                market_type  => 'all',
                currency     => 'USD',
            )
        },
        undef,
        'create real account'
    );

    is(
        exception {
            $dxtrader_cr->deposit(
                to_account => $account->{account_id},
                amount     => 10,
                currency   => 'USD',
            )
        },
        undef,
        'SVG to SVG deposit'
    );

    my $e = exception {
        $dxtrader_mf->deposit(
            to_account => $account->{account_id},
            amount     => 10,
            currency   => 'USD',
        )
    };

    is $e->{error_code}, 'DifferentLandingCompanies', 'MF to SVG deposit';

    is(
        exception {
            $dxtrader_cr->withdraw(
                from_account => $account->{account_id},
                amount       => 5,
                currency     => 'USD',
            )
        },
        undef,
        'SVG to SVG withdraw'
    );

    $e = exception {
        $dxtrader_mf->withdraw(
            from_account => $account->{account_id},
            amount       => 5,
            currency     => 'USD',
        )
    };

    is $e->{error_code}, 'DifferentLandingCompanies', 'MF to SVG withdraw';
};

subtest 'tradding accounts for wallet accounts' => sub {
    $dxconfig->suspend->all(0);
    $dxconfig->suspend->demo(0);
    $dxconfig->suspend->real(0);

    my ($user, $wallet_generator) = BOM::Test::Helper::Client::create_wallet_factory('za', 'Gauteng');

    my ($wallet) = $wallet_generator->(qw(CRW doughflow USD));

    my $dxtrader_cr = BOM::TradingPlatform->new(
        platform    => 'dxtrade',
        client      => $wallet,
        rule_engine => BOM::Rules::Engine->new(client => $wallet),
    );

    my $account = $dxtrader_cr->new_account(
        account_type => 'real',
        password     => 'test',
        market_type  => 'all',
        currency     => 'USD',
    );

    ok($account->{account_id}, "Account was successfully created");
    is($user->get_accounts_links->{$account->{account_id}}[0]{loginid}, $wallet->loginid, 'Account is linked to the doughflow wallet');

    my $err = exception {
        $dxtrader_cr->new_account(
            account_type => 'real',
            password     => 'test',
            market_type  => 'all',
            currency     => 'USD'
        );
    };

    is($err->{error_code}, 'DXExistingAccount', 'Fail to create duplicate account under the same wallet');

    $err = exception {
        $dxtrader_cr->new_account(
            account_type => 'demo',
            password     => 'test',
            market_type  => 'all',
            currency     => 'USD'
        );
    };

    is($err->{error_code}, 'TradingPlatformInvalidAccount', 'Fail to create demo account from real money wallet');

    is scalar($dxtrader_cr->get_accounts()->@*), 1, "Linked account is returned in account list";

    my ($p2p_wallet) = $wallet_generator->(qw(CRW p2p USD));

    my $dxtrader_p2p = BOM::TradingPlatform->new(
        platform    => 'dxtrade',
        client      => $p2p_wallet,
        rule_engine => BOM::Rules::Engine->new(client => $p2p_wallet),
    );

    my $account1 = $dxtrader_p2p->new_account(
        account_type => 'real',
        password     => 'test',
        market_type  => 'all',
        currency     => 'USD',
    );

    ok($account1->{account_id}, "Account is successfully created from P2P wallet");
    is($user->get_accounts_links->{$account1->{account_id}}[0]{loginid}, $p2p_wallet->loginid, 'Account is linked to the wallet');
    is scalar($dxtrader_p2p->get_accounts()->@*), 1, "Linked account is returned in account list";

    my ($virtual_wallet) = $wallet_generator->(qw(VRW virtual USD));

    my $dxtrader_virtual = BOM::TradingPlatform->new(
        platform    => 'dxtrade',
        client      => $virtual_wallet,
        rule_engine => BOM::Rules::Engine->new(client => $virtual_wallet),
    );

    $err = exception {
        $dxtrader_virtual->new_account(
            account_type => 'real',
            password     => 'test',
            market_type  => 'all',
            currency     => 'USD'
        );
    };

    is($err->{error_code}, 'AccountShouldBeReal', 'Fail to create real money account from virtual wallet');

    my $account2 = $dxtrader_virtual->new_account(
        account_type => 'demo',
        password     => 'test',
        market_type  => 'all',
        currency     => 'USD',
    );

    ok($account2->{account_id}, "Demo account was successfully create from virtual wallet");
    is($user->get_accounts_links->{$account2->{account_id}}[0]{loginid}, $virtual_wallet->loginid, 'Account was linked to the wallet');
    is scalar($dxtrader_virtual->get_accounts()->@*), 1, "Linked account is returned in account list";

    my ($crypto_wallet) = $wallet_generator->(qw(CRW crypto USD));

    my $dxtrader_cypto = BOM::TradingPlatform->new(
        platform    => 'dxtrade',
        client      => $crypto_wallet,
        rule_engine => BOM::Rules::Engine->new(client => $crypto_wallet),
    );

    $err = exception {
        $dxtrader_cypto->new_account(
            account_type => 'real',
            password     => 'test',
            market_type  => 'all',
            currency     => 'USD'
        );
    };

    ok($err, "Fail to create dxtrader account from wallet which is not supported by dxtrade account type");
    is($err->{error_code}, 'TradingPlatformInvalidAccount', 'Got expected error code');
    is scalar($dxtrader_cypto->get_accounts()->@*), 0, "Linked account is returned in account list -> none ";
};

done_testing();

sub _get_transaction_details {
    my ($dbic, $transaction_id) = @_;

    my ($result) = $dbic->run(
        fixup => sub {
            $_->selectrow_array('select details from transaction.transaction_details where transaction_id = ?', undef, $transaction_id,);
        });
    return JSON::MaybeUTF8::decode_json_utf8($result);
}

