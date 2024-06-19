use strict;
use warnings;

use Test::More;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::P2PWithClient;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

BOM::Test::Helper::P2PWithClient::bypass_sendbird();
BOM::Test::Helper::P2PWithClient::create_escrow();

my $advertiser_names = {
    first_name => 'john',
    last_name  => 'smith'
};
my $client_names = {
    first_name => 'mary',
    last_name  => 'jane'
};

my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(advertiser => {%$advertiser_names});
my $client = BOM::Test::Helper::P2PWithClient::create_advertiser(client_details => {%$client_names});

my $order = $client->p2p_order_create(
    advert_id   => $advert->{id},
    amount      => 10,
    rule_engine => BOM::Rules::Engine->new());

my $names_shown = sub {
    my ($order, $desc) = @_;
    is $order->{client_details}{first_name},     $client_names->{first_name},     "$desc client first_name returned";
    is $order->{client_details}{last_name},      $client_names->{last_name},      "$desc client last_name returned";
    is $order->{advertiser_details}{first_name}, $advertiser_names->{first_name}, "$desc advertiser first_name returned";
    is $order->{advertiser_details}{last_name},  $advertiser_names->{last_name},  "$desc advertiser last_name returned";
};

$names_shown->($order,                                                       'order create');
$names_shown->($client->p2p_order_info(id => $order->{id}),                  'p2p_order_info for client, status: pending');
$names_shown->($advertiser->p2p_order_info(id => $order->{id}),              'p2p_order_info for advertiser, status: pending');
$names_shown->($client->p2p_order_list(id => $order->{id})->{list}->[0],     'p2p_order_list for client, status: pending');
$names_shown->($advertiser->p2p_order_list(id => $order->{id})->{list}->[0], 'p2p_order_list for advertiser, status: pending');

for my $active_status (qw/buyer-confirmed timed-out disputed completed cancelled refunded dispute-refunded dispute-completed/) {
    BOM::Test::Helper::P2PWithClient::set_order_status($client, $order->{id}, $active_status);

    $names_shown->($client->p2p_order_info(id => $order->{id}),                  'p2p_order_info for client, status: ' . $active_status);
    $names_shown->($advertiser->p2p_order_info(id => $order->{id}),              'p2p_order_info for advertiser, status: ' . $active_status);
    $names_shown->($client->p2p_order_list(id => $order->{id})->{list}->[0],     'p2p_order_list for client, status: ' . $active_status);
    $names_shown->($advertiser->p2p_order_list(id => $order->{id})->{list}->[0], 'p2p_order_list for advertiser, status: ' . $active_status);
}

BOM::Test::Helper::P2PWithClient::reset_escrow();

done_testing;
