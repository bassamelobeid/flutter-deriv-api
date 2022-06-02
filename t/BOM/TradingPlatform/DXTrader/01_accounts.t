use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;

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
    market_type  => 'synthetic',
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
        market_type           => 'synthetic',
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
        attributes   => {
            clearing_code => 'default',
            client_domain => 'default',
            login         => re('^TEST\d+$'),
            account_code  => $account1->{account_id},
            market_type   => 'synthetic',
        }
    },
    'user attributes of first account'
);

%params = (
    account_type => 'real',
    password     => 'test',
    market_type  => 'synthetic',
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
        market_type           => 'synthetic',
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
        attributes   => {
            login         => $account2->{login},
            clearing_code => 'default',
            client_domain => 'default',
            account_code  => $account2->{account_id},
            market_type   => 'synthetic',
        }
    },
    'user attributes of second account'
);

cmp_deeply(
    exception {
        $dxtrader->new_account(
            account_type => 'demo',
            password     => 'test',
            market_type  => 'synthetic',
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
    market_type           => 'synthetic',
    landing_company_short => 'svg',
};

my $suspend_account2 = {
    account_id            => 'DXR1001',
    account_type          => 'real',
    enabled               => 0,
    currency              => 'USD',
    login                 => $account2->{login},
    platform              => 'dxtrade',
    market_type           => 'synthetic',
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

my $account3 = $dxtrader->new_account(
    account_type => 'real',
    password     => 'test',
    market_type  => 'financial',
    currency     => 'USD',
);

cmp_deeply(
    $account3,
    {
        account_id            => 'DXR1002',
        account_type          => 'real',
        enabled               => 1,
        balance               => num(0),
        currency              => 'USD',
        display_balance       => '0.00',
        login                 => $account1->{login},
        platform              => 'dxtrade',
        market_type           => 'financial',
        landing_company_short => 'svg',
    },
    'created third account'
);

cmp_deeply([$client->user->get_trading_platform_loginids('dxtrader')], bag(qw/DXD1000 DXR1001 DXR1002/), 'Correct loginids reported');

cmp_deeply([$client->user->get_trading_platform_loginids('dxtrader', 'demo')], bag(qw/DXD1000/), 'Correct loginids reported');

cmp_deeply([$client->user->get_trading_platform_loginids('dxtrader', 'real')], bag(qw/DXR1001 DXR1002/), 'Correct loginids reported');

$real_account_ids_offset = 618;

my $account4 = $dxtrader->new_account(
    account_type => 'demo',
    password     => 'test',
    market_type  => 'financial',
    currency     => 'USD',
);

cmp_deeply(
    $account4,
    {
        account_id            => 'DXD1621',
        account_type          => 'demo',
        enabled               => 1,
        balance               => num(10000),
        currency              => 'USD',
        display_balance       => '10000.00',
        login                 => $account1->{login},
        platform              => 'dxtrade',
        market_type           => 'financial',
        landing_company_short => 'svg',
    },
    'created 4th account'
);

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

    is(
        exception {
            $dxtrader->new_account(
                account_type => 'demo',
                password     => 'test',
                market_type  => 'synthetic',
                currency     => 'USD',
            )
        },
        undef,
        'create demo account'
    );

    my $account;
    is(
        exception {
            $account = $dxtrader->new_account(
                account_type => 'real',
                password     => 'test',
                market_type  => 'synthetic',
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

