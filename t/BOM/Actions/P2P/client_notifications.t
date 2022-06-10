use strict;
use warnings;

use Test::More;
use BOM::Event::Actions::P2P;

use RedisDB;
use BOM::Config::Redis;
use BOM::Test::Helper::P2P;
use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

use JSON::MaybeUTF8 qw(decode_json_utf8);

BOM::Test::Helper::P2P::bypass_sendbird();

my $escrow = BOM::Test::Helper::P2P::create_escrow();
my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
    amount => 100,
    type   => 'sell'
);
my ($client, $order) = BOM::Test::Helper::P2P::create_order(
    advert_id => $advert->{id},
    amount    => 100
);

my $proc = BOM::Event::Process->new(category => 'generic');

my $expected_data = [
    {%{$advertiser->p2p_order_info(id => $order->{id})}, advertiser_loginid => $advertiser->loginid},
    {%{$client->p2p_order_info(id => $order->{id})},     client_loginid     => $client->loginid},
];

my $advertiser_id = $advertiser->{_p2p_advertiser_cached}{id};
delete $advertiser->{_p2p_advertiser_cached};    # delete cache

my @data_for_notification_tests = ({
        name  => 'order updated (no event)',
        event => 'p2p_order_created',
        data  => {
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        },
        channel  => join(q{::} => ('P2P::ORDER::NOTIFICATION', uc($client->broker), uc($client->residence), uc($client->currency))),
        expected => $expected_data,
    },
    {
        name  => 'order updated (created)',
        event => 'p2p_order_updated',
        data  => {
            client_loginid => $client->loginid,
            order_id       => $order->{id},
            order_event    => 'created',
        },
        channel  => join(q{::} => ('P2P::ORDER::NOTIFICATION', uc($client->broker), uc($client->residence), uc($client->currency))),
        expected => $expected_data,
    },
    {
        name  => 'advertiser updated (self)',
        event => 'p2p_advertiser_updated',
        data  => {
            client_loginid => $advertiser->loginid,
        },
        channel  => join(q{::} => ('P2P::ADVERTISER::NOTIFICATION', $advertiser->loginid, $advertiser->loginid)),
        expected => [$advertiser->p2p_advertiser_info],
    },
    {
        name  => 'advertiser updated (other advertiser)',
        event => 'p2p_advertiser_updated',
        data  => {
            client_loginid => $advertiser->loginid,
        },
        channel  => join(q{::} => ('P2P::ADVERTISER::NOTIFICATION', $advertiser->loginid, $client->loginid)),
        expected => [$client->p2p_advertiser_info(id => $advertiser_id)],
    },
);

for my $test_data (@data_for_notification_tests) {
    subtest $test_data->{name} => sub {
        # Separate connection is needed, because BOM::User::Client will execute the same redis
        # which is not allowed when waiting for replies on the same connection
        my $connection_config = BOM::Config::redis_p2p_config()->{p2p}{read};
        my $p2p_redis         = RedisDB->new(
            host => $connection_config->{host},
            port => $connection_config->{port},
            ($connection_config->{password} ? ('password' => $connection_config->{password}) : ()));

        #Yes, this's really need, because when we're trying to get_reply,
        # and after time out, auto reconnecting for some reason doesn't work
        $p2p_redis->_connect();

        my @got_notification;
        $p2p_redis->subscribe($test_data->{channel}, sub { push @got_notification, $_[3] });
        $p2p_redis->get_reply;
        $proc->process({
                type    => $test_data->{event},
                details => $test_data->{data},
            },
            'some_stream'
        );
        eval { $p2p_redis->get_reply for (1 .. $test_data->{expected}->@*) };
        my @notifications = map {
            eval { decode_json_utf8($_) }
                || undef
        } @got_notification;

        is_deeply(\@notifications, $test_data->{expected}, 'Got expected payload');
    };
}

BOM::Test::Helper::P2P::reset_escrow();

done_testing()
