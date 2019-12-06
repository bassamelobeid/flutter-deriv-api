use strict;
use warnings;

use Test::More;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::OTC;
use BOM::Config::Runtime;
use Test::Fatal;
use Data::Dumper;

subtest 'Client cancellation at pending status' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::OTC::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => $amount);
    my ($client, $order) = BOM::Test::Helper::OTC::create_order(
        offer_id => $offer->{id},
        amount   => $amount
    );

    ok($escrow->account->balance == $amount, 'Escrow balance is correct');
    ok($agent->account->balance == 0,        'Agent balance is correct');
    ok($client->account->balance == 0,       'Client balance is correct');

    $client->cancel_otc_order(id => $order->{id});

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');
    ok($client->account->balance == 0,      'Client balance is correct');

    my $order_data = $client->get_otc_order($order->{id});

    is($order_data->{status}, 'cancelled', 'Status for new order is correct');
    ok($order_data->{amount} == $amount, 'Amount for new order is correct');
    is($order_data->{client_loginid}, $client->loginid, 'Client for new order is correct');
    is($order_data->{agent_loginid},  $agent->loginid,  'Agent for new order is correct');
    is($order_data->{description},    $description,     'Description for new order is correct');

    BOM::Test::Helper::OTC::reset_escrow();
};

subtest 'Client cancellation at client-confirmed status' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::OTC::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => $amount);
    my ($client, $order) = BOM::Test::Helper::OTC::create_order(
        offer_id => $offer->{id},
        amount   => $amount
    );

    ok($escrow->account->balance == $amount, 'Escrow balance is correct');
    ok($agent->account->balance == 0,        'Agent balance is correct');
    ok($client->account->balance == 0,       'Client balance is correct');

    $client->confirm_otc_order(id => $order->{id});

    my $order_data = $client->get_otc_order($order->{id});
    is($order_data->{status}, 'client-confirmed', 'Status for new order is correct');

    $client->cancel_otc_order(id => $order->{id});

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');
    ok($client->account->balance == 0,      'Client balance is correct');

    $order_data = $client->get_otc_order($order->{id});

    is($order_data->{status}, 'cancelled', 'Status for new order is correct');
    ok($order_data->{amount} == $amount, 'Amount for new order is correct');
    is($order_data->{client_loginid}, $client->loginid, 'Client for new order is correct');
    is($order_data->{agent_loginid},  $agent->loginid,  'Agent for new order is correct');
    is($order_data->{description},    $description,     'Description for new order is correct');

    BOM::Test::Helper::OTC::reset_escrow();
};

subtest 'Agent cancellation' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::OTC::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => $amount);
    my ($client, $order) = BOM::Test::Helper::OTC::create_order(
        offer_id => $offer->{id},
        amount   => $amount
    );

    ok($escrow->account->balance == $amount, 'Escrow balance is correct');
    ok($agent->account->balance == 0,        'Agent balance is correct');
    ok($client->account->balance == 0,       'Client balance is correct');

    my $err = exception { $agent->cancel_otc_order(id => $order->{id}) };
    chomp($err);

    is $err, 'PermissionDenied', 'Got correct error code';

    ok($escrow->account->balance == $amount, 'Escrow balance is correct');
    ok($agent->account->balance == 0,        'Agent balance is correct');
    ok($client->account->balance == 0,       'Client balance is correct');

    my $order_data = $client->get_otc_order($order->{id});

    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{amount} == $amount, 'Amount for new order is correct');
    is($order_data->{client_loginid}, $client->loginid, 'Client for new order is correct');
    is($order_data->{agent_loginid},  $agent->loginid,  'Agent for new order is correct');
    is($order_data->{description},    $description,     'Description for new order is correct');

    BOM::Test::Helper::OTC::reset_escrow();
};

done_testing();
