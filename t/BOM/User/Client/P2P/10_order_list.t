use strict;
use warnings;

use Test::More;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use Test::MockModule;

BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([]);
BOM::Test::Helper::P2P::bypass_sendbird();

my %ad_params = (
    amount         => 100,
    rate           => 1.1,
    type           => 'sell',
    description    => 'ad description',
    payment_method => 'bank_transfer',
    payment_info   => 'ad pay info',
    contact_info   => 'ad contact info',
    local_currency => 'sgd',
);

my $escrow         = BOM::Test::Helper::P2P::create_escrow();
my @created_orders = ();

my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
    %ad_params,
    advertiser => {
        first_name => 'john',
        last_name  => 'smith'
    });

my $client = BOM::Test::Helper::P2P::create_advertiser(
    client_details => {
        first_name => 'mary',
        last_name  => 'jane'
    });
my $new_order = $client->p2p_order_create(
    advert_id => $advert_info->{id},
    amount    => 20,
    expiry    => 7200,
);
push @created_orders, $new_order;

note explain $@;
my $second_client = BOM::Test::Helper::P2P::create_advertiser(
    client_details => {
        first_name => 'mary2',
        last_name  => 'jane2'
    });
my $new_order2 = $second_client->p2p_order_create(
    advert_id => $advert_info->{id},
    amount    => 20,
    expiry    => 7200,
);
push @created_orders, $new_order2;

my $third_client = BOM::Test::Helper::P2P::create_advertiser(
    client_details => {
        first_name => 'mary3',
        last_name  => 'jane3'
    });
my $new_order3 = $third_client->p2p_order_create(
    advert_id => $advert_info->{id},
    amount    => 20,
    expiry    => 7200,
);
push @created_orders, $new_order3;

my $fourth_client = BOM::Test::Helper::P2P::create_advertiser(
    client_details => {
        first_name => 'mary4',
        last_name  => 'jane4'
    });
my $new_order4 = $fourth_client->p2p_order_create(
    advert_id => $advert_info->{id},
    amount    => 20,
    expiry    => 7200,
);
push @created_orders, $new_order4;

my $active_statuses   = qr{pending|buyer-confirmed|timed-out};
my $deactive_statuses = qr{completed|cancelled|refunded};

subtest "check active orders" => sub {
    my $orders = $advertiser->p2p_order_list(
        advert_id => $advert_info->{id},
        active    => 1,
    );

    my @correct_statuses = grep { $_->{status} =~ $active_statuses } $orders->@*;

    ok scalar $orders->@* == scalar @created_orders,   "Active orders number is correct";
    ok scalar $orders->@* == scalar @correct_statuses, "All active order have correct status";
};

subtest "check inactive orders" => sub {
    my $orders = $advertiser->p2p_order_list(
        advert_id => $advert_info->{id},
        active    => 0,
    );

    my @correct_statuses = grep { $_->{status} =~ $active_statuses } $orders->@*;

    ok scalar $orders->@* == 0, "Inactive orders number is correct as 0";

    $fourth_client->p2p_order_cancel(id => $new_order4->{id});

    $orders = $advertiser->p2p_order_list(
        advert_id => $advert_info->{id},
        active    => 0,
    );

    @correct_statuses = grep { $_->{status} =~ $deactive_statuses } $orders->@*;

    ok scalar $orders->@* == 1, "Inactive orders number is correct";
    ok scalar $orders->@* == scalar @correct_statuses, "All active order have correct status";
};

subtest "check all orders" => sub {
    my $orders = $advertiser->p2p_order_list(
        advert_id => $advert_info->{id},
    );

    ok scalar $orders->@* == scalar @created_orders, "All orders number is correct when active parameter is absent.";
};

BOM::Test::Helper::P2P::reset_escrow();

done_testing();
