use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::Test::Helper qw/build_wsapi_test test_schema/;
use BOM::Test::Helper::Client;

use await;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::Platform::Token::API;

my $t = build_wsapi_test();

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);
$client->account('USD');

my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token', ['read', 'admin']);

$t->await::authorize({authorize => $token});

my $acc = $t->await::trading_platform_new_account({
    trading_platform_new_account => 1,
    platform                     => 'dxtrade',
    account_type                 => 'demo',
    market_type                  => 'financial',
    password                     => 'Test1234',
});

test_schema('trading_platform_new_account', $acc);

my $list = $t->await::trading_platform_accounts({
    trading_platform_accounts => 1,
    platform                  => 'dxtrade',
});

test_schema('trading_platform_accounts', $list);

cmp_deeply($list->{trading_platform_accounts}, [$acc->{trading_platform_new_account}], 'responses match');

BOM::Test::Helper::Client::top_up($client, 'USD', 10);

my $dep = $t->await::trading_platform_deposit({
    trading_platform_deposit => 1,
    platform                 => 'dxtrade',
    from_account             => $client->loginid,
    to_account               => $acc->{account_id},
});
test_schema('trading_platform_deposit', $dep);

my $wd = $t->await::trading_platform_withdrawal({
    trading_platform_withdrawal => 1,
    platform                 => 'dxtrade',
    from_account             => $acc->{account_id},
    to_account               => $client->loginid,
});
test_schema('trading_platform_withdrawal', $wd);

$t->finish_ok;

done_testing();
