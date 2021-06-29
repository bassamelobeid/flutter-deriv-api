use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::Test::Helper::Client;
use BOM::TradingPlatform;
use BOM::Config::Runtime;

my $app_config = BOM::Config::Runtime->instance->app_config->system;
$app_config->suspend->wallets(1);
$app_config->dxtrade->suspend->all(0);
$app_config->dxtrade->suspend->demo(0);
$app_config->dxtrade->suspend->real(0);

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
    server        => $account->{account_type},
    method        => 'account_withdrawal',
    account_code  => $meta->{attributes}{account_code},
    clearing_code => $meta->{attributes}{clearing_code},
    id            => $dxtrader->unique_id,
    amount        => $account->{balance} - 1000,
    currency      => $account->{currency},
);

$app_config->dxtrade->suspend->all(1);
cmp_deeply(exception { $dxtrader->deposit(to_account => $account->{account_id}) }, {error_code => 'DXSuspended'}, 'error when all suspended');
$app_config->dxtrade->suspend->all(0);

$app_config->dxtrade->suspend->demo(1);
cmp_deeply(exception { $dxtrader->deposit(to_account => $account->{account_id}) }, {error_code => 'DXServerSuspended'}, 'error when demo suspended');
$app_config->dxtrade->suspend->demo(0);
$app_config->dxtrade->suspend->real(1);

is exception {
    $dxtrader->deposit(to_account => $account->{account_id});
}, undef, 'can top up at 1000 and real is suspended';

my $resp = $dxtrader->call_api(
    server        => $account->{account_type},
    method        => 'account_get',
    account_code  => $meta->{attributes}{account_code},
    clearing_code => $meta->{attributes}{clearing_code},
);

cmp_ok $resp->{content}{balance}, '==', 11000, 'expected account balance after top up';

done_testing();
