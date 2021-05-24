use strict;
use warnings;
use Test::More;
use Test::Fatal;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::Test::Helper::Client;
use BOM::TradingPlatform;
use BOM::Config::Runtime;

BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);
BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});

BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);

$client->account('USD');

my $dxtrader = BOM::TradingPlatform->new(
    platform => 'dxtrade',
    client   => $client
);

my $account = $dxtrader->new_account(
    account_type => 'demo',
    password     => 'test',
    currency     => 'USD',
    market_type  => 'financial',
);

is exception {
    $dxtrader->deposit(to_account => $account->{account_id});
}
->{error_code}, 'DXDemoTopupBalance', 'cannot top up with big balance';

my $meta = $client->user->loginid_details->{$account->{account_id}};

$dxtrader->call_api(
    $account->{account_type},
    'account_withdrawal',
    account_code  => $meta->{attributes}{account_code},
    clearing_code => $meta->{attributes}{clearing_code},
    id            => $dxtrader->unique_id,
    amount        => $account->{balance} - 1000,
    currency      => $account->{currency},
);

is exception {
    $dxtrader->deposit(to_account => $account->{account_id});
}, undef, 'can top up at 1000';

my $resp = $dxtrader->call_api(
    $account->{account_type},
    'account_get',
    account_code  => $meta->{attributes}{account_code},
    clearing_code => $meta->{attributes}{clearing_code},
);

cmp_ok $resp->{content}{balance}, '==', 11000, 'expected account balance after top up';

done_testing();
