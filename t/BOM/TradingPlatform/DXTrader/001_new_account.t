use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::TradingPlatform;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);

my $dxtrader = BOM::TradingPlatform->new(
    platform => 'dxtrade',
    client   => $client
);
isa_ok($dxtrader, 'BOM::TradingPlatform::DXTrader');

cmp_deeply(
    exception {
        $dxtrader->new_account(
            account_type => 'demo',
            password     => 'test'
        )
    },
    {
        error_code => 'DXtradeNoCurrency',
    },
    'no account and no currency'
);

$client->account('USD');

my $account1 = $dxtrader->new_account(
    account_type => 'demo',
    password     => 'test'
);

cmp_deeply(
    $account1,
    {
        account_id            => 'DXD1000',
        account_type          => 'demo',
        balance               => '0.00',
        currency              => 'USD',
        display_balance       => '0.00',
        login                 => re('\w{40}'),
        platform              => 'dxtrade',
        market_type           => 'financial',
        landing_company_short => 'svg',
        sub_account_type      => 'financial',
    },
    'created first account'
);

cmp_deeply(
    $client->user->loginid_details->{$account1->{account_id}},
    {
        platform     => 'dxtrade',
        currency     => $account1->{currency},
        account_type => $account1->{account_type},
        attributes   => {
            clearing_code    => 'default',
            client_domain    => 'default',
            login            => re('\w{40}'),
            account_code     => re('\w{40}'),
            trading_category => 'test',
        }
    },
    'user attributes of first account'
);

my $account2 = $dxtrader->new_account(
    account_type => 'real',
    currency     => 'SGD',
    password     => 'test',
);

cmp_deeply(
    $account2,
    {
        account_id            => 'DXR1001',
        account_type          => 'real',
        balance               => '0.00',
        currency              => 'SGD',
        display_balance       => '0.00',
        login                 => re('\w{40}'),
        platform              => 'dxtrade',
        market_type           => 'financial',
        landing_company_short => 'svg',
        sub_account_type      => 'financial',
    },
    'created second account'
);

cmp_deeply(
    $client->user->loginid_details->{$account2->{account_id}},
    {
        platform     => 'dxtrade',
        currency     => $account2->{currency},
        account_type => $account2->{account_type},
        attributes   => {
            login            => re('\w{40}'),
            clearing_code    => 'default',
            client_domain    => 'default',
            account_code     => re('\w{40}'),
            trading_category => 'test',
        }
    },
    'user attributes of second account'
);

cmp_deeply(
    exception {
        $dxtrader->new_account(
            account_type => 'demo',
            password     => 'test'
        )
    },
    {
        error_code     => 'ExistingDXtradeAccount',
        message_params => [re('\w{40}')],
    },
    'cannot create duplicate account'
);

cmp_deeply($dxtrader->get_accounts, [$account1, $account2], 'account list');

done_testing();
