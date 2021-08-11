use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::Event::Actions::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use RedisDB;
use JSON::MaybeUTF8 qw(decode_json_utf8);

my $connection_config = BOM::Config::redis_p2p_config->{p2p}{read};
my $redis             = RedisDB->new(
    host => $connection_config->{host},
    port => $connection_config->{port},
    ($connection_config->{password} ? ('password' => $connection_config->{password}) : ()));

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

my ($advertiser, $advert1) = BOM::Test::Helper::P2P::create_advert(rate => 1);
my $advertiser_id = $advertiser->_p2p_advertiser_cached->{id};

my $client    = BOM::Test::Helper::P2P::create_advertiser;
my $client_id = $client->_p2p_advertiser_cached->{id};

$redis->del('P2P::ADVERT_STATE::' . $advertiser_id);
$redis->del('P2P::ADVERT_STATE::' . $client_id);

subtest 'subscribe to all' => sub {

    my $channel = 'P2P::ADVERT::' . $advertiser_id . '::' . $advertiser->account->id . '::' . $advertiser->loginid . '::ALL';
    $redis->subscribe($channel);
    $redis->get_reply;

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
        channels      => [$channel],
    });
    my $message = decode_json_utf8($redis->get_reply->[2]);
    cmp_deeply $message, $advert1, 'unseen advert was published';

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
        channels      => [$channel],
    });
    ok !$redis->reply_ready, 'another event causes no publish';

    $advert1 = $advertiser->p2p_advert_update(
        id        => $advert1->{id},
        is_active => 0
    );

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
    });
    $message = decode_json_utf8($redis->get_reply->[2]);
    cmp_deeply $message, $advert1, 'updated advert was published';

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
    });
    ok !$redis->reply_ready, 'another event causes no publish';

    my $advert2 = (
        BOM::Test::Helper::P2P::create_advert(
            client => $advertiser,
            rate   => 2
        ))[1];

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
    });
    $message = decode_json_utf8($redis->get_reply->[2]);
    cmp_deeply $message, $advert2, 'new advert was published';

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
    });
    ok !$redis->reply_ready, 'another event causes no publish';

    $advert1 = $advertiser->p2p_advert_update(
        id     => $advert1->{id},
        delete => 1
    );

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
    });
    $message = decode_json_utf8($redis->get_reply->[2]);
    cmp_deeply $message, $advert1, 'deleted advert was published';

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
    });
    ok !$redis->reply_ready, 'another event causes no publish';

};

subtest 'single ad' => sub {

    my $advert_id = $advertiser->p2p_advertiser_adverts->[0]->{id};
    my $advertiser_single_channel =
        'P2P::ADVERT::' . $advertiser_id . '::' . $advertiser->account->id . '::' . $advertiser->loginid . '::' . $advert_id;
    my $advertiser_all_channel = 'P2P::ADVERT::' . $advertiser_id . '::' . $advertiser->account->id . '::' . $advertiser->loginid . '::ALL';
    $redis->subscribe($advertiser_single_channel);    # we are already subscribed to ALL
    $redis->get_reply;

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
    });
    ok !$redis->reply_ready, 'no publish because we already saw this ad';

    my $order = $client->p2p_order_create(
        advert_id => $advert_id,
        amount    => 10
    );

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
    });

    my $advert  = $advertiser->p2p_advert_info(id => $advert_id);
    my @replies = map { my $reply = $redis->get_reply; [$reply->[1], decode_json_utf8($reply->[2])] } 0 .. 1;

    cmp_deeply(
        \@replies,
        bag([$advertiser_all_channel, $advert], [$advertiser_single_channel, $advert]),
        'got 2 replies because we are also subscribed to all',
    );

    my $client_channel = 'P2P::ADVERT::' . $advertiser_id . '::' . $advertiser->account->id . '::' . $client->loginid . '::' . $advert_id;
    $redis->subscribe($client_channel);
    $redis->get_reply;

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
    });

    my $message = decode_json_utf8($redis->get_reply->[2]);
    cmp_deeply $message, $client->p2p_advert_info(id => $advert_id), 'client gets message on subscribe';

    $client->p2p_advertiser_relations(add_favourites => [$advertiser_id]);

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
    });

    $message = decode_json_utf8($redis->get_reply->[2]);
    cmp_deeply $message, $client->p2p_advert_info(id => $advert_id), 'client gets message after favouriting advertiser';

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
    });
    ok !$redis->reply_ready, 'no messages for other subscribers';

    $client->p2p_order_cancel(id => $order->{id});

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
    });

    @replies = map { my $reply = $redis->get_reply; [$reply->[1], decode_json_utf8($reply->[2])] } 0 .. 2;

    cmp_deeply(
        \@replies,
        bag(
            [$advertiser_single_channel, $advertiser->p2p_advert_info(id => $advert_id)],
            [$advertiser_all_channel,    $advertiser->p2p_advert_info(id => $advert_id)],
            [$client_channel,            $client->p2p_advert_info(id => $advert_id)]
        ),
        'got 3 replies after cancelling ad',
    );

    $advert = $advertiser->p2p_advert_update(
        id     => $advert_id,
        delete => 1
    );

    BOM::Event::Actions::P2P::p2p_adverts_updated({
        advertiser_id => $advertiser_id,
    });

    @replies = map { my $reply = $redis->get_reply; [$reply->[1], decode_json_utf8($reply->[2])] } 0 .. 2;

    cmp_deeply(
        \@replies,
        bag([$advertiser_single_channel, $advert], [$advertiser_all_channel, $advert], [$client_channel, $advert]),
        'got 3 replies after deleting ad',
    );

};

done_testing();
