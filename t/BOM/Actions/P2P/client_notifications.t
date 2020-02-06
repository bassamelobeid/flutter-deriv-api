use strict;
use warnings;

use Test::More;
use feature 'state';
use BOM::Event::Actions::P2P;

use BOM::Test;
use BOM::Config::Runtime;
use Data::Dumper;
use BOM::Database::ClientDB;
use BOM::Config::RedisReplicated;
use BOM::Test::Helper::P2P;
use BOM::Event::Process;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

use JSON::MaybeUTF8 qw(decode_json_utf8);

my $escrow = BOM::Test::Helper::P2P::create_escrow();
my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => 100);
my ($client, $order) = BOM::Test::Helper::P2P::create_order(
    offer_id => $offer->{offer_id},
    amount   => 100
);

my $expected_data = $client->p2p_order_info(order_id => $order->{order_id});
$expected_data->{agent_loginid} = $agent->loginid;
$expected_data->{client_loginid} = $client->loginid;

my @data_for_notification_tests = ({
        event => 'p2p_order_created',
        data  => {
            client_loginid => $client->loginid,
            order_id       => $order->{order_id},
        },
        channel => join(q{::} => ('P2P::ORDER::NOTIFICATION', uc($client->broker), uc($client->residence), uc($client->currency))),
        expected => $expected_data,
    },
    {
        event => 'p2p_order_updated',
        data  => {
            client_loginid => $client->loginid,
            order_id       => $order->{order_id},
        },
        channel => join(q{::} => ('P2P::ORDER::NOTIFICATION', uc($client->broker), uc($client->residence), uc($client->currency))),
        expected => $expected_data,
    },
);

for my $test_data (@data_for_notification_tests) {
    subtest 'Notification for ' . $test_data->{event} => sub {
        my $p2p_redis = BOM::Config::RedisReplicated->redis_p2p();
        #Yes, this's really need, because when we're trying to get_reply,
        # and after time out, auto reconnecting for some reason doesn't work
        $p2p_redis->_connect();

        my $got_notification;
        $p2p_redis->subscribe($test_data->{channel}, sub { $got_notification = $_[3] });
        $p2p_redis->get_reply;

        BOM::Event::Process::process({
                type    => $test_data->{event},
                details => $test_data->{data},
            },
            $test_data->{event});

        eval { $p2p_redis->get_reply };

        my $notification = eval { $got_notification && decode_json_utf8($got_notification) };
        is_deeply($notification, $test_data->{expected}, 'No notification abount an order');
    };
}

BOM::Test::Helper::P2P::reset_escrow();

done_testing()
