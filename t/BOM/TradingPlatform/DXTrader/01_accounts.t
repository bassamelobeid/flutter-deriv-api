use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::TradingPlatform;
use BOM::Config::Runtime;
use Test::MockModule;

BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

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
    platform => 'dxtrade',
    client   => $client
);
isa_ok($dxtrader, 'BOM::TradingPlatform::DXTrader');

$real_account_ids_login_prefix = 'TEST';
my $account1 = $dxtrader->new_account(
    account_type => 'demo',
    password     => 'test',
    market_type  => 'synthetic',
    currency     => 'USD',
);

cmp_deeply(
    $account1,
    {
        account_id            => 'DXD1000',
        account_type          => 'demo',
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

my $account2 = $dxtrader->new_account(
    account_type => 'real',
    password     => 'test',
    market_type  => 'synthetic',
    currency     => 'USD',
);

cmp_deeply(
    $account2,
    {
        account_id            => 'DXR1001',
        account_type          => 'real',
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

cmp_deeply([$client->user->get_trading_platform_loginids('dxtrader', 'demo')], bag(qw/DXD1000/), 'Correct loginids reported');

cmp_deeply([$client->user->get_trading_platform_loginids('dxtrader', 'real')], bag(qw/DXR1001/), 'Correct loginids reported');

cmp_deeply(
    $client->user->loginid_details->{$account2->{account_id}},
    {
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

done_testing();

sub _get_transaction_details {
    my ($dbic, $transaction_id) = @_;

    my ($result) = $dbic->run(
        fixup => sub {
            $_->selectrow_array('select details from transaction.transaction_details where transaction_id = ?', undef, $transaction_id,);
        });
    return JSON::MaybeUTF8::decode_json_utf8($result);
}

