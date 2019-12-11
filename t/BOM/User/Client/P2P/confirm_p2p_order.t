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

subtest 'Client confirmation' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        offer_id => $offer->{id},
        amount   => $amount
    );

    ok($escrow->account->balance == $amount, 'Escrow balance is correct');
    ok($agent->account->balance == 0,        'Agent balance is correct');
    ok($client->account->balance == 0,       'Client balance is correct');

    $client->p2p_order_confirm(id => $order->{id});

    ok($escrow->account->balance == $amount, 'Escrow balance is correct');
    ok($agent->account->balance == 0,        'Agent balance is correct');
    ok($client->account->balance == 0,       'Client balance is correct');

    my $order_data = $client->p2p_order($order->{id});

    is($order_data->{status}, 'client-confirmed', 'Status for new order is correct');
    ok($order_data->{amount} == $amount, 'Amount for new order is correct');
    is($order_data->{client_loginid}, $client->loginid, 'Client for new order is correct');
    is($order_data->{agent_loginid},  $agent->loginid,  'Agent for new order is correct');
    is($order_data->{description},    $description,     'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Agent confirmation' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        offer_id => $offer->{id},
        amount   => $amount
    );

    ok($escrow->account->balance == $amount, 'Escrow balance is correct');
    ok($agent->account->balance == 0,        'Agent balance is correct');
    ok($client->account->balance == 0,       'Client balance is correct');

    $client->p2p_order_confirm(id => $order->{id});
    $agent->p2p_order_confirm(id => $order->{id});

    ok($escrow->account->balance == 0,       'Escrow balance is correct');
    ok($agent->account->balance == 0,        'Agent balance is correct');
    ok($client->account->balance == $amount, 'Client balance is correct');

    my $order_data = $client->p2p_order($order->{id});

    is($order_data->{status}, 'completed', 'Status for new order is correct');
    ok($order_data->{amount} == $amount, 'Amount for new order is correct');
    is($order_data->{client_loginid}, $client->loginid, 'Client for new order is correct');
    is($order_data->{agent_loginid},  $agent->loginid,  'Agent for new order is correct');
    is($order_data->{description},    $description,     'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Agent confirmation before client' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        offer_id => $offer->{id},
        amount   => $amount
    );

    ok($escrow->account->balance == $amount, 'Escrow balance is correct');
    ok($agent->account->balance == 0,        'Agent balance is correct');
    ok($client->account->balance == 0,       'Client balance is correct');

    my $err = exception { $agent->p2p_order_confirm(id => $order->{id}) };
    chomp $err;

    is $err, 'InvalidStateForAgentConfirmation', 'Got expected error';

    ok($escrow->account->balance == $amount, 'Escrow balance is correct');
    ok($agent->account->balance == 0,        'Agent balance is correct');
    ok($client->account->balance == 0,       'Client balance is correct');

    my $order_data = $client->p2p_order($order->{id});

    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{amount} == $amount, 'Amount for new order is correct');
    is($order_data->{client_loginid}, $client->loginid, 'Client for new order is correct');
    is($order_data->{agent_loginid},  $agent->loginid,  'Agent for new order is correct');
    is($order_data->{description},    $description,     'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

done_testing();
