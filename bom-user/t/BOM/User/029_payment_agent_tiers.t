use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Customer;
use BOM::Database::ClientDB;

my $db = BOM::Database::ClientDB->new({broker_code => 'CR'})->db->dbic->dbh;

my $test_customer = BOM::Test::Customer->create(
    clients => [{
            name        => 'CR',
            broker_code => 'CR',
        }]);
my $client = $test_customer->get_client_object('CR');

$client->payment_agent({
    payment_agent_name    => 'x',
    email                 => $client->email,
    information           => 'x',
    summary               => 'x',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    status                => 'authorized',
    currency_code         => 'USD',
    is_listed             => 't',
});

$client->save;

cmp_deeply(
    $client->get_payment_agent->tier_details,
    {
        cashier_withdraw => 0,
        p2p              => 0,
        trading          => 0,
        transfer_to_pa   => 0,
        name             => 'default',
    },
    'default supported services'
);

$db->do('SELECT betonmarkets.pa_tier_update(?,?,?,?,?,?)', undef, 1, 'default', 1, 0, 1, 0);

cmp_deeply(
    $client->get_payment_agent->tier_details,
    {
        cashier_withdraw => 1,
        p2p              => 0,
        trading          => 1,
        transfer_to_pa   => 0,
        name             => 'default',
    },
    'update the default supported services'
);

my $id = $db->selectrow_array('SELECT id FROM betonmarkets.pa_tier_create(?,?,?,?,?)', undef, 'mytier', 0, 1, 0, 1);

$client->get_payment_agent->tier_id($id);
$client->save;

cmp_deeply(
    $client->get_payment_agent->tier_details,
    {
        cashier_withdraw => 0,
        p2p              => 1,
        trading          => 0,
        transfer_to_pa   => 1,
        name             => 'mytier',
    },
    'new tier assigned'
);

$db->do('SELECT betonmarkets.pa_tier_delete(?)', undef, $id);
$client = BOM::User::Client->new({loginid => $client->loginid});    # need to reload client

cmp_deeply(
    $client->get_payment_agent->tier_details,
    {
        cashier_withdraw => 1,
        p2p              => 0,
        trading          => 1,
        transfer_to_pa   => 0,
        name             => 'default',
    },
    'back to default after tier is deleted'
);

done_testing;
