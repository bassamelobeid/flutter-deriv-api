use strict;
use warnings;
use Test::More;
use RedisDB;
use BOM::Config::Redis;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::P2PWithClient;
use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Customer;
use P2P;

use JSON::MaybeUTF8 qw(decode_json_utf8);

BOM::Test::Helper::P2PWithClient::bypass_sendbird();

my $service_contexts = BOM::Test::Customer::get_service_contexts();

my $escrow = BOM::Test::Helper::P2PWithClient::create_escrow();
my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
    amount      => 100,
    type        => 'sell',
    description => 'instruction 1'
);
my ($client, $order) = BOM::Test::Helper::P2PWithClient::create_order(
    advert_id => $advert->{id},
    amount    => 100
);

my $client_id = P2P->new(client => $client)->_p2p_advertiser_cached->{id};
delete $client->{_p2p_advertiser_cached};    # delete cache

my $proc = BOM::Event::Process->new(category => 'generic');

my $connection_config = BOM::Config::redis_p2p_config()->{p2p}{write};

my $advertiser_id = $advertiser->{_p2p_advertiser_cached}{id};
$client->p2p_advertiser_relations(add_blocked => [$advertiser_id]);
$advertiser->p2p_advert_update(
    id          => $advert->{id},
    description => "instruction 2"
);

delete $advertiser->{_p2p_advertiser_cached};    # delete cache
my $client_order     = $client->p2p_order_info(id => $order->{id});
my $advertiser_order = $advertiser->p2p_order_info(id => $order->{id});

delete $client_order->{subscription_info};
delete $advertiser_order->{subscription_info};

my @data_for_notification_tests = ({
        name  => 'order created',
        event => 'p2p_order_created',
        data  => {
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        },
        expected => {
            'P2P::ORDER::NOTIFICATION::'
                . uc($client->broker)
                . '::'
                . $client->loginid
                . '::'
                . $client_id
                . '::'
                . -1
                . '::'
                . -1
                . '::'
                . -1 => [$client_order],
            'P2P::ORDER::NOTIFICATION::'
                . uc($advertiser->broker)
                . '::'
                . $advertiser->loginid
                . '::'
                . $advertiser_id
                . '::'
                . -1
                . '::'
                . -1
                . '::'
                . -1 => [$advertiser_order],
        }
    },
    {
        name  => 'order updated',
        event => 'p2p_order_updated',
        data  => {
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        },
        expected => {
            'P2P::ORDER::NOTIFICATION::'
                . uc($client->broker)
                . '::'
                . $client->loginid
                . '::'
                . $client_id
                . '::'
                . -1
                . '::'
                . -1
                . '::'
                . -1 => [$client_order],
            'P2P::ORDER::NOTIFICATION::'
                . uc($advertiser->broker)
                . '::'
                . $advertiser->loginid
                . '::'
                . $advertiser_id
                . '::'
                . -1
                . '::'
                . -1
                . '::'
                . -1 => [$advertiser_order],
        }
    },
    {
        name  => 'order updated (client only)',
        event => 'p2p_order_updated',
        data  => {
            client_loginid => $client->loginid,
            order_id       => $order->{id},
            self_only      => 1,
        },
        expected => {
                  'P2P::ORDER::NOTIFICATION::'
                . uc($client->broker)
                . '::'
                . $client->loginid . '::'
                . $client_id . '::'
                . -1 . '::'
                . -1 . '::'
                . -1 => [$client_order],
        }
    },
    {
        name  => 'order updated due to advert changes (client only)',
        event => 'p2p_advert_orders_updated',
        data  => {
            client_loginid => $client->loginid,
            advert_id      => $advert->{id},
        },
        expected => {
                  'P2P::ORDER::NOTIFICATION::'
                . uc($client->broker) . '::'
                . $client->loginid . '::'
                . $client_id . '::'
                . -1 . '::'
                . $order->{id} . '::'
                . -1 => [$client_order],
        }
    },
    {
        name  => 'order updated (advertiser only)',
        event => 'p2p_order_updated',
        data  => {
            client_loginid => $advertiser->loginid,
            order_id       => $order->{id},
            self_only      => 1,
        },
        expected => {
                  'P2P::ORDER::NOTIFICATION::'
                . uc($advertiser->broker) . '::'
                . $advertiser->loginid . '::'
                . $advertiser_id . '::'
                . -1 . '::'
                . -1 . '::'
                . -1 => [$advertiser_order],
        }
    },
    {
        name  => 'advertiser updated (self)',
        event => 'p2p_advertiser_updated',
        data  => {
            client_loginid => $advertiser->loginid,
        },
        expected => {
            'P2P::ADVERTISER::NOTIFICATION::' . $advertiser->loginid . '::' . $advertiser->loginid => [$advertiser->p2p_advertiser_info],
        }
    },
    {
        name  => 'advertiser updated (other advertiser)',
        event => 'p2p_advertiser_updated',
        data  => {
            client_loginid => $advertiser->loginid,
        },
        expected => {
                  'P2P::ADVERTISER::NOTIFICATION::'
                . $advertiser->loginid . '::'
                . $client->loginid => [$client->p2p_advertiser_info(id => $advertiser_id)],
        }
    },
    {
        name  => 'advertiser updated (both)',
        event => 'p2p_advertiser_updated',
        data  => {
            client_loginid => $advertiser->loginid,
        },
        expected => {
            'P2P::ADVERTISER::NOTIFICATION::' . $advertiser->loginid . '::' . $advertiser->loginid => [$advertiser->p2p_advertiser_info],
            'P2P::ADVERTISER::NOTIFICATION::'
                . $advertiser->loginid . '::'
                . $client->loginid => [$client->p2p_advertiser_info(id => $advertiser_id)],
        }
    },
);

for my $test_data (@data_for_notification_tests) {

    subtest $test_data->{name} => sub {
        my $redis = RedisDB->new(
            host => $connection_config->{host},
            port => $connection_config->{port},
            ($connection_config->{password} ? ('password' => $connection_config->{password}) : ()));

        my %msgs;
        for my $channel (keys $test_data->{expected}->%*) {
            $redis->subscribe($channel, sub { push $msgs{$channel}->@*, decode_json_utf8($_[3]) });
            $redis->get_reply;
        }

        $proc->process({
                type    => $test_data->{event},
                details => $test_data->{data},
            },
            'some_stream',
            $service_contexts
        );

        $redis->get_reply for map { $test_data->{expected}->{$_} } keys $test_data->{expected}->%*;
        is_deeply(\%msgs, $test_data->{expected}, 'Got expected payload');
    };
}
BOM::Test::Helper::P2P::reset_escrow();

done_testing()
