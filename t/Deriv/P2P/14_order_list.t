use strict;
use warnings;

use Test::More;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use Test::MockModule;
use BOM::Rules::Engine;

my $rule_engine = BOM::Rules::Engine->new();

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$config->escrow([]);
$config->order_timeout(3600);

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
    advert_id   => $advert_info->{id},
    amount      => 20,
    rule_engine => $rule_engine,
);
push @created_orders, $new_order;

my $second_client = BOM::Test::Helper::P2P::create_advertiser(
    client_details => {
        first_name => 'mary2',
        last_name  => 'jane2'
    });
my $new_order2 = $second_client->p2p_order_create(
    advert_id   => $advert_info->{id},
    amount      => 20,
    rule_engine => $rule_engine,
);
push @created_orders, $new_order2;

my $third_client = BOM::Test::Helper::P2P::create_advertiser(
    client_details => {
        first_name => 'mary3',
        last_name  => 'jane3'
    });
my $new_order3 = $third_client->p2p_order_create(
    advert_id   => $advert_info->{id},
    amount      => 20,
    rule_engine => $rule_engine,
);
push @created_orders, $new_order3;

my $fourth_client = BOM::Test::Helper::P2P::create_advertiser(
    client_details => {
        first_name => 'mary4',
        last_name  => 'jane4'
    });
my $new_order4 = $fourth_client->p2p_order_create(
    advert_id   => $advert_info->{id},
    amount      => 20,
    rule_engine => $rule_engine,
);
push @created_orders, $new_order4;

my $active_statuses   = qr{pending|buyer-confirmed|timed-out|disputed};
my $inactive_statuses = qr{completed|cancelled|refunded|dispute-refunded|dispute-completed};

subtest "check active orders" => sub {
    my $orders = $advertiser->p2p_order_list(
        advert_id => $advert_info->{id},
        active    => 1,
    );

    my @correct_statuses = grep { $_->{status} =~ $active_statuses } $orders->{list}->@*;

    ok scalar $orders->{list}->@* == scalar @created_orders,   "Active orders number is correct";
    ok scalar $orders->{list}->@* == scalar @correct_statuses, "All active order have correct status";
};

my $expected_inactive = 1;
subtest "check inactive orders" => sub {
    my $orders = $advertiser->p2p_order_list(
        advert_id => $advert_info->{id},
        active    => 0,
    );

    my @correct_statuses = grep { $_->{status} =~ $active_statuses } $orders->{list}->@*;

    ok scalar $orders->{list}->@* == 0, "Inactive orders number is correct as 0";

    $fourth_client->p2p_order_cancel(id => $new_order4->{id});

    $orders = $advertiser->p2p_order_list(
        advert_id => $advert_info->{id},
        active    => 0,
    );

    @correct_statuses = grep { $_->{status} =~ $inactive_statuses } $orders->{list}->@*;

    ok scalar $orders->{list}->@* == $expected_inactive,       "Inactive orders number is correct";
    ok scalar $orders->{list}->@* == scalar @correct_statuses, "All active order have correct status";
};

subtest "check all orders" => sub {
    my $orders = $advertiser->p2p_order_list(
        advert_id => $advert_info->{id},
    );

    ok scalar $orders->{list}->@* == scalar @created_orders, "All orders number is correct when active parameter is absent.";
};

subtest 'dispute statuses' => sub {
    my @dispute_statuses = qw/disputed dispute-refunded dispute-completed/;
    foreach my $dispute_status (@dispute_statuses) {
        my $nth_client = BOM::Test::Helper::P2P::create_advertiser(
            client_details => {
                first_name => 'maryN',
                last_name  => 'janeN'
            });

        my $new_orderN = $nth_client->p2p_order_create(
            advert_id   => $advert_info->{id},
            amount      => 10,
            rule_engine => $rule_engine,
        );
        BOM::Test::Helper::P2P::set_order_status($nth_client, $new_orderN->{id}, $dispute_status);
        push @created_orders, $new_orderN;
    }

    my $orders_active = $advertiser->p2p_order_list(
        advert_id => $advert_info->{id},
        active    => 1,
    );
    my $orders_inactive = $advertiser->p2p_order_list(
        advert_id => $advert_info->{id},
        active    => 0,
    );
    my $orders = $advertiser->p2p_order_list(
        advert_id => $advert_info->{id},
    );

    my $expected_total = scalar @created_orders;

    # We added 2 inactive orders
    $expected_inactive += 2;

    # We added 1 active order but good old algebra suffices
    my $expected_active = $expected_total - $expected_inactive;

    is scalar $orders->{list}->@*,          $expected_total,    "Total orders number is correct";
    is scalar $orders_active->{list}->@*,   $expected_active,   "Active orders number is correct";
    is scalar $orders_inactive->{list}->@*, $expected_inactive, "Inactive orders number is correct";

};

subtest 'Filter date' => sub {
    my @created_orders_for_date = ();
    my ($advertiser_for_date, $advert_info_for_date) = BOM::Test::Helper::P2P::create_advert(
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
    my $order1 = $client->p2p_order_create(
        advert_id   => $advert_info_for_date->{id},
        amount      => 20,
        expiry      => 7200,
        rule_engine => $rule_engine,
    );
    push @created_orders_for_date, $order1;

    my $client2 = BOM::Test::Helper::P2P::create_advertiser(
        client_details => {
            first_name => 'mary2',
            last_name  => 'jane2'
        });
    my $order2 = $client2->p2p_order_create(
        advert_id   => $advert_info_for_date->{id},
        amount      => 20,
        expiry      => 7200,
        rule_engine => $rule_engine,
    );
    push @created_orders_for_date, $order2;

    my $client3 = BOM::Test::Helper::P2P::create_advertiser(
        client_details => {
            first_name => 'mary3',
            last_name  => 'jane3'
        });
    my $order3 = $client3->p2p_order_create(
        advert_id   => $advert_info_for_date->{id},
        amount      => 20,
        expiry      => 7200,
        rule_engine => $rule_engine,
    );
    push @created_orders_for_date, $order3;

    my $client4 = BOM::Test::Helper::P2P::create_advertiser(
        client_details => {
            first_name => 'mary4',
            last_name  => 'jane4'
        });
    my $order4 = $client4->p2p_order_create(
        advert_id   => $advert_info_for_date->{id},
        amount      => 20,
        expiry      => 7200,
        rule_engine => $rule_engine,
    );
    push @created_orders_for_date, $order4;

    $advertiser->db->dbic->run(
        fixup => sub {
            $_->do('UPDATE p2p.p2p_order SET created_time = ? WHERE id = ?;', {Slice => {}}, '2020-01-01', $order1->{id});
        });

    $advertiser->db->dbic->run(
        fixup => sub {
            $_->do('UPDATE p2p.p2p_order SET created_time = ? WHERE id = ?;', {Slice => {}}, '2020-01-01 01:02:03', $order2->{id});
        });

    $advertiser->db->dbic->run(
        fixup => sub {
            $_->do('UPDATE p2p.p2p_order SET created_time = ? WHERE id = ?;', {Slice => {}}, '2020-01-02', $order3->{id});
        });

    my $all_orders = $advertiser_for_date->p2p_order_list();

    my $from_date_orders = $advertiser_for_date->p2p_order_list(date_from => '2020-01-01 01:02:03');

    my $from_and_to_orders = $advertiser_for_date->p2p_order_list(
        date_from => '2020-01-01',
        date_to   => '2020-01-02'
    );

    my $to_orders = $advertiser_for_date->p2p_order_list(date_to => '2020-01-01 01:02:03');

    my $expected_total = scalar @created_orders_for_date;

    is scalar $all_orders->{list}->@*,         $expected_total, "Total orders number is correct";
    is scalar $from_date_orders->{list}->@*,   3,               "Old orders filters";
    is scalar $from_and_to_orders->{list}->@*, 3,               "New orders filters";
    is scalar $to_orders->{list}->@*,          2,               "New orders filters";

};

BOM::Test::Helper::P2P::reset_escrow();
done_testing();
