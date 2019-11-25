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

use JSON::MaybeUTF8 qw(decode_json_utf8);

my $dbh = BOM::Database::ClientDB->new({
        broker_code => 'CR',
        operation   => 'write'
    })->db->dbh;

subtest pending_order_expiry => sub {
    my $escrow = create_escrow();
    my $client = create_client();
    my $agent  = create_agent();

    my $offer = create_offer($agent, 'sell', 100, 'test offer');
    my $order = create_order($offer, $client, $escrow, 99, 1, 'test order');

    my $otc_redis = BOM::Config::RedisReplicated->redis_otc();

    my $got_notification;
    $otc_redis->subscribe('OTC::ORDER::NOTIFICATION::' . $order->{order_id}, sub { $got_notification = $_[3] });
    $otc_redis->get_reply;

    BOM::Event::Actions::OTC::order_expired({
        order_id    => $order->{order_id},
        broker_code => 'CR'
    });
    eval { $otc_redis->get_reply };

    my $update_order = get_order($order->{order_id});

    is $update_order->{status}, 'cancelled', "Got expected status";

    ok($got_notification, 'Got notification abount an order');
    my $notification = eval { decode_json_utf8($got_notification) } // {};

    my $expected_notification = {
        order_id   => $order->{order_id},
        event      => 'status_changed',
        event_data => {
            new_status => 'cancelled',
            old_status => 'pending',
        }};

    is_deeply $notification, $expected_notification, 'Notification is valid';
};

subtest client_confirmed_order_expiry => sub {
    my $escrow = create_escrow();
    my $client = create_client();
    my $agent  = create_agent();

    my $offer = create_offer($agent, 'sell', 100, 'test offer');
    my $order = create_order($offer, $client, $escrow, 100, 1, 'test order');

    set_order_status($order->{order_id}, 'client-confirmed');

    my $otc_redis = BOM::Config::RedisReplicated->redis_otc();

    my $got_notification;
    $otc_redis->subscribe('OTC::ORDER::NOTIFICATION::' . $order->{order_id}, sub { $got_notification = $_[3] });
    $otc_redis->get_reply;

    BOM::Event::Actions::OTC::order_expired({
        order_id    => $order->{order_id},
        broker_code => 'CR'
    });
    eval { $otc_redis->get_reply };

    my $update_order = get_order($order->{order_id});

    is $update_order->{status}, 'timed-out', "Got expected status";

    ok($got_notification, 'Got notification abount an order');
    my $notification = eval { decode_json_utf8($got_notification) } // {};

    my $expected_notification = {
        order_id   => $order->{order_id},
        event      => 'status_changed',
        event_data => {
            new_status => 'timed-out',
            old_status => 'client-confirmed',
        }};

    is_deeply $notification, $expected_notification, 'Notification is valid';
};

for my $test_status (qw(completed cancelled refunded timed-out)) {
    subtest "${test_status}_order_expiry" => sub {
        my $escrow = create_escrow();
        my $client = create_client();
        my $agent  = create_agent();

        my $offer = create_offer($agent, 'sell', 100, 'test offer');
        my $order = create_order($offer, $client, $escrow, 100, 1, 'test order');

        set_order_status($order->{order_id}, $test_status);

        my $otc_redis = BOM::Config::RedisReplicated->redis_otc();
        #Yes, this's really need, because when we're trying to get_reply,
        # and after time out, auto reconnecting for some reason doesn't work
        $otc_redis->_connect();

        my $got_notification;
        $otc_redis->subscribe('OTC::ORDER::NOTIFICATION::' . $order->{order_id}, sub { $got_notification = $_[3] });
        $otc_redis->get_reply;

        BOM::Event::Actions::OTC::order_expired({
            order_id    => $order->{order_id},
            broker_code => 'CR'
        });
        eval { $otc_redis->get_reply };

        my $update_order = get_order($order->{order_id});

        is $update_order->{status}, $test_status, "Got expected status";

        ok(!$got_notification, 'No notification abount an order');
    };
}

# Helpers for creating mock data.
#TODO: better to move these methods to some where in bom-test.
sub create_escrow {
    state $escrow;

    return $escrow if $escrow;

    $escrow = BOM::Test::Helper::Client::create_client();
    BOM::Test::Helper::Client::top_up($escrow, $escrow->currency, 100);
    BOM::Config::Runtime->instance->app_config->payments->otc->escrow([$escrow->loginid]);

    return $escrow;
}

sub create_client {
    my $buyer = BOM::Test::Helper::Client::create_client();
    BOM::Test::Helper::Client::top_up($buyer, $buyer->currency, 100);
    $dbh->do(q{select * from otc.agent_create(?)}, undef, $buyer->loginid);

    return $buyer;
}

sub create_agent {
    my $seller = BOM::Test::Helper::Client::create_client();
    BOM::Test::Helper::Client::top_up($seller, $seller->currency, 100);
    $dbh->do(q{select * from otc.agent_create(?)}, undef, $seller->loginid);
    $dbh->do(q{select * from otc.agent_update(?, ?, ?)}, undef, $seller->loginid, 1, 1);

    return $seller;
}

sub create_offer {
    my ($seller, $type, $amount, $remark) = @_;

    return $dbh->selectrow_hashref(q{select * from otc.offer_create(?, ?, ?, ?, ?, ?)},
        undef, $seller->loginid, $type, $seller->currency, $amount, $remark, $seller->residence);
}

sub create_order {
    my ($offer, $buyer, $escrow, $amount, $source, $remark) = @_;

    return $dbh->selectrow_hashref(q{select * from otc.order_create(?, ?, ?, ?, ?, ?, ?)},
        undef, $offer->{id}, $buyer->loginid, $escrow->loginid, $amount, $remark, $source, $buyer->loginid);
}

sub get_order {
    my ($order_id) = @_;

    return $dbh->selectrow_hashref(
        'SELECT id, status, client_confirmed, offer_currency currency FROM otc.order_list(?,?,?,?)',
        undef, $order_id, (undef) x 3,
    );
}

sub set_order_status {
    my ($order_id, $new_status) = @_;

    return $dbh->selectrow_hashref('SELECT * FROM otc.order_update(?, ?)', undef, $order_id, $new_status);
}

done_testing();
