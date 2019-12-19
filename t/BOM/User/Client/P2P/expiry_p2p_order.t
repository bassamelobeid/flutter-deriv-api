use strict;
use warnings;

use Test::More;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use Test::Fatal;
use Data::Dumper;

subtest 'Expire order in pending state' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        offer_id => $offer->{id},
        amount   => $amount
    );

    cmp_ok($escrow->account->balance, '==', $amount, 'Escrow balance is correct');
    cmp_ok($agent->account->balance,  '==', 0,       'Agent balance is correct');
    cmp_ok($client->account->balance, '==', 0,       'Client balance is correct');

    $client->p2p_expire_order(id => $order->{id});

    cmp_ok($escrow->account->balance, '==', 0,       'Escrow balance is correct');
    cmp_ok($agent->account->balance,  '==', $amount, 'Agent balance is correct');
    cmp_ok($client->account->balance, '==', 0,       'Client balance is correct');

    my $order_data = $client->p2p_order($order->{id});

    is($order_data->{status}, 'cancelled', 'Status for new order is correct');
    cmp_ok($order_data->{amount}, '==', $amount, 'Amount for new order is correct');
    is($order_data->{client_loginid}, $client->loginid, 'Client for new order is correct');
    is($order_data->{agent_loginid},  $agent->loginid,  'Agent for new order is correct');
    is($order_data->{description},    $description,     'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Expire order in client confirmed state' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        offer_id => $offer->{id},
        amount   => $amount
    );

    $client->p2p_order_confirm(id => $order->{id});

    cmp_ok($escrow->account->balance, '==', $amount, 'Escrow balance is correct');
    cmp_ok($agent->account->balance,  '==', 0,       'Agent balance is correct');
    cmp_ok($client->account->balance, '==', 0,       'Client balance is correct');

    $client->p2p_expire_order(id => $order->{id});

    cmp_ok($escrow->account->balance, '==', 0,       'Escrow balance is correct');
    cmp_ok($agent->account->balance,  '==', $amount, 'Agent balance is correct');
    cmp_ok($client->account->balance, '==', 0,       'Client balance is correct');

    my $order_data = $client->p2p_order($order->{id});

    is($order_data->{status}, 'cancelled', 'Status for new order is correct');
    cmp_ok($order_data->{amount}, '==', $amount, 'Amount for new order is correct');
    is($order_data->{client_loginid}, $client->loginid, 'Client for new order is correct');
    is($order_data->{agent_loginid},  $agent->loginid,  'Agent for new order is correct');
    is($order_data->{description},    $description,     'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

for my $test_status (qw(completed cancelled refunded timed-out)) {
    subtest "Expire order in ${test_status} state" => sub {
        my $amount      = 100;
        my $description = 'Test order';
        my $source      = 1;

        my $escrow = BOM::Test::Helper::P2P::create_escrow();
        my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
        my ($client, $order) = BOM::Test::Helper::P2P::create_order(
            offer_id => $offer->{id},
            amount   => $amount
        );

        BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, $test_status);

        cmp_ok($escrow->account->balance, '==', $amount, 'Escrow balance is correct');
        cmp_ok($agent->account->balance,  '==', 0,       'Agent balance is correct');
        cmp_ok($client->account->balance, '==', 0,       'Client balance is correct');

        $client->p2p_expire_order(id => $order->{id});

        cmp_ok($escrow->account->balance, '==', $amount, 'Escrow balance is correct');
        cmp_ok($agent->account->balance,  '==', 0,       'Agent balance is correct');
        cmp_ok($client->account->balance, '==', 0,       'Client balance is correct');

        my $order_data = $client->p2p_order($order->{id});

        is($order_data->{status}, $test_status, 'Status for new order is correct');
        cmp_ok($order_data->{amount}, '==', $amount, 'Amount for new order is correct');
        is($order_data->{client_loginid}, $client->loginid, 'Client for new order is correct');
        is($order_data->{agent_loginid},  $agent->loginid,  'Agent for new order is correct');
        is($order_data->{description},    $description,     'Description for new order is correct');

        BOM::Test::Helper::P2P::reset_escrow();
    };
}

done_testing();
