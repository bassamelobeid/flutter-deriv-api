use strict;
use warnings;

use Test::More;
use feature 'state';
use BOM::Event::Actions::OTC;

use BOM::Test;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Config::Runtime;
use Data::Dumper;
use BOM::Database::ClientDB;
use BOM::Config::RedisReplicated;
use BOM::Test::Helper::OTC;

use JSON::MaybeUTF8 qw(decode_json_utf8);

subtest pending_order_expiry => sub {
    my $escrow = BOM::Test::Helper::OTC::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => 100);
    my ($client, $order) = BOM::Test::Helper::OTC::create_order(
        offer_id => $offer->{id},
        amount   => 100
    );

    my $otc_redis = BOM::Config::RedisReplicated->redis_otc();

    my $got_notification;
    $otc_redis->subscribe('OTC::ORDER::NOTIFICATION::' . $order->{id}, sub { $got_notification = $_[3] });
    $otc_redis->get_reply;

    BOM::Event::Actions::OTC::order_expired({
        order_id    => $order->{id},
        broker_code => 'CR'
    });
    eval { $otc_redis->get_reply };

    my $update_order = $client->get_otc_order($order->{id});

    is $update_order->{status}, 'cancelled', "Got expected status";

    ok($got_notification, 'Got notification abount an order');
    my $notification = eval { decode_json_utf8($got_notification) } // {};

    my $expected_notification = {
        order_id   => $order->{id},
        event      => 'status_changed',
        event_data => {
            new_status => 'cancelled',
            old_status => 'pending',
        }};

    is_deeply $notification, $expected_notification, 'Notification is valid';

    BOM::Test::Helper::OTC::reset_escrow();
};

subtest client_confirmed_order_expiry => sub {
    my $escrow = BOM::Test::Helper::OTC::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => 100);
    my ($client, $order) = BOM::Test::Helper::OTC::create_order(
        offer_id => $offer->{id},
        amount   => 100
    );

    $client->confirm_otc_order(id => $order->{id});

    my $otc_redis = BOM::Config::RedisReplicated->redis_otc();

    my $got_notification;
    $otc_redis->subscribe('OTC::ORDER::NOTIFICATION::' . $order->{id}, sub { $got_notification = $_[3] });
    $otc_redis->get_reply;

    BOM::Event::Actions::OTC::order_expired({
        order_id    => $order->{id},
        broker_code => 'CR'
    });
    eval { $otc_redis->get_reply };

    my $update_order = $client->get_otc_order($order->{id});

    is $update_order->{status}, 'timed-out', "Got expected status";

    ok($got_notification, 'Got notification abount an order');
    my $notification = eval { decode_json_utf8($got_notification) } // {};

    my $expected_notification = {
        order_id   => $order->{id},
        event      => 'status_changed',
        event_data => {
            new_status => 'timed-out',
            old_status => 'client-confirmed',
        }};

    is_deeply $notification, $expected_notification, 'Notification is valid';

    BOM::Test::Helper::OTC::reset_escrow();
};

for my $test_status (qw(completed cancelled refunded timed-out)) {
    subtest "${test_status}_order_expiry" => sub {
        my $escrow = BOM::Test::Helper::OTC::create_escrow();
        my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => 100);
        my ($client, $order) = BOM::Test::Helper::OTC::create_order(
            offer_id => $offer->{id},
            amount   => 100
        );

        BOM::Test::Helper::OTC::set_order_status($client, $order->{id}, $test_status);

        my $otc_redis = BOM::Config::RedisReplicated->redis_otc();
        #Yes, this's really need, because when we're trying to get_reply,
        # and after time out, auto reconnecting for some reason doesn't work
        $otc_redis->_connect();

        my $got_notification;
        $otc_redis->subscribe('OTC::ORDER::NOTIFICATION::' . $order->{id}, sub { $got_notification = $_[3] });
        $otc_redis->get_reply;

        BOM::Event::Actions::OTC::order_expired({
            order_id    => $order->{id},
            broker_code => 'CR'
        });
        eval { $otc_redis->get_reply };

        my $update_order = $client->get_otc_order($order->{id});

        is $update_order->{status}, $test_status, "Got expected status";

        ok(!$got_notification, 'No notification abount an order');

        BOM::Test::Helper::OTC::reset_escrow();
    };
}

done_testing();
