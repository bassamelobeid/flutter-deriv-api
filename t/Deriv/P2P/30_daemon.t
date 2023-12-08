use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;
use Test::MockObject;
use Test::MockTime qw(set_fixed_time);
use RedisDB;

use BOM::Config;
use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::User::Script::P2PDaemon;

my $emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => sub { push $emitted_events->{$_[0]}->@*, $_[1] });

# need a separate connection for subscribe mode
my $redis_config = BOM::Config::redis_p2p_config();
my $p2p_redis    = RedisDB->new(
    host => $redis_config->{host},
    port => $redis_config->{port},
);

my $p2p_config = BOM::Config::Runtime->instance->app_config->payments->p2p;

set_fixed_time(CORE::time());

sub clear_redis {
    $p2p_redis->del($_)
        for
        qw(P2P::ORDER::DISPUTED_AT P2P::ORDER::EXPIRES_AT P2P::ORDER::TIMEDOUT_AT P2P::ADVERTISER::BLOCK_ENDS_AT P2P::USERS_ONLINE P2P::USERS_ONLINE_LATEST P2P::ORDER::REVIEWABLE_START_AT P2P::ORDER::VERIFICATION_EVENT);
}

subtest 'expired orders' => sub {
    clear_redis();
    $emitted_events = {};

    my $daemon = BOM::User::Script::P2PDaemon->new;

    my @items = (
        time() - 1 => '1|CR001',
        time()     => '2|CR002',
        time() + 1 => '3|CR003',
    );

    $p2p_redis->zadd('P2P::ORDER::EXPIRES_AT', @items);

    $daemon->on_sec;

    cmp_deeply(
        $emitted_events,
        {
            p2p_order_expired => bag({
                    order_id       => 1,
                    client_loginid => 'CR001',
                },
                {
                    order_id       => 2,
                    client_loginid => 'CR002',
                },
            )
        },
        'expected p2p_order_expired events emitted'
    );

    cmp_deeply(
        {$p2p_redis->zrange('P2P::ORDER::EXPIRES_AT', 0, -1, 'WITHSCORES')->@*},
        {
            '1|CR001' => time + 30,
            '2|CR002' => time + 30,
            '3|CR003' => time + 1,
        },
        'processing retry added to processed items'
    );
};

subtest 'refund timedout orders' => sub {
    clear_redis();
    $emitted_events = {};

    $p2p_config->refund_timeout(1);
    my $threshold = time - (24 * 60 * 60);
    my $daemon    = BOM::User::Script::P2PDaemon->new;

    my @items = (
        $threshold - 1 => '1|CR001',
        $threshold     => '2|CR002',
        $threshold + 1 => '3|CR003',
    );

    $p2p_redis->zadd('P2P::ORDER::TIMEDOUT_AT', @items);

    $daemon->on_sec;

    cmp_deeply(
        $emitted_events,
        {
            p2p_timeout_refund => bag({
                    order_id       => 1,
                    client_loginid => 'CR001',

                },
                {
                    order_id       => 2,
                    client_loginid => 'CR002',
                },
            )
        },
        'expected p2p_timeout_refund events emitted'
    );

    cmp_deeply(
        {$p2p_redis->zrange('P2P::ORDER::TIMEDOUT_AT', 0, -1, 'WITHSCORES')->@*},
        {
            '1|CR001' => $threshold + 30,
            '2|CR002' => $threshold + 30,
            '3|CR003' => $threshold + 1,
        },
        'processing retry added to processed items'
    );
};

subtest 'process disputes' => sub {
    clear_redis();
    $emitted_events = {};

    $p2p_config->disputed_timeout(1);
    my $threshold = time - 3600;

    my $daemon = BOM::User::Script::P2PDaemon->new;

    my @items = (
        $threshold - 1 => '1|CR',
        $threshold     => '2|CR',
        $threshold + 1 => '3|CR',
    );

    $p2p_redis->zadd('P2P::ORDER::DISPUTED_AT', @items);

    $daemon->on_sec;

    cmp_deeply(
        $emitted_events,
        {
            p2p_dispute_expired => bag({
                    broker_code => 'CR',
                    order_id    => '1',
                    timestamp   => $threshold - 1,
                },
                {
                    broker_code => 'CR',
                    order_id    => '2',
                    timestamp   => $threshold,
                })
        },
        'expected p2p_dispute_expired events emitted'
    );

    cmp_deeply($p2p_redis->zrange('P2P::ORDER::DISPUTED_AT', 0, -1, 'WITHSCORES'), ['3|CR', $threshold + 1], 'processed items removed from redis');

};

subtest 'advertiser blocks ending' => sub {
    clear_redis();
    $emitted_events = {};

    my $threshold = time - 1;

    my $daemon = BOM::User::Script::P2PDaemon->new;

    my @items = (
        $threshold - 1 => 'CR001',
        $threshold     => 'CR002',
        $threshold + 1 => 'CR003',
    );

    $p2p_redis->zadd('P2P::ADVERTISER::BLOCK_ENDS_AT', @items);

    $daemon->on_sec;

    cmp_deeply(
        $emitted_events,
        {
            p2p_advertiser_updated => bag({
                    client_loginid => 'CR001',
                },
                {
                    client_loginid => 'CR002',
                },
            )
        },
        'expected p2p_advertiser_updated events emitted'
    );

    cmp_deeply(
        $p2p_redis->zrange('P2P::ADVERTISER::BLOCK_ENDS_AT', 0, -1, 'WITHSCORES'),
        ['CR003', $threshold + 1],
        'processed items removed from redis'
    );
};

subtest 'advertisers online/offline' => sub {
    clear_redis();
    $emitted_events = {};

    my $daemon = BOM::User::Script::P2PDaemon->new;

    my @items = (
        time()      => 'CR001::za',
        time() - 89 => 'CR002::id',
        time() - 90 => 'CR003::ng',
        time() - 91 => 'CR004::pt',
    );

    $p2p_redis->zadd('P2P::USERS_ONLINE', @items);
    $daemon->on_sec;

    cmp_deeply(
        $emitted_events,
        {
            p2p_advertiser_online_status => bag({
                    client_loginid => 'CR001',
                },
                {
                    client_loginid => 'CR002',
                },
                {
                    client_loginid => 'CR003',
                },
            )
        },
        'expected p2p_advertiser_updated events emitted'
    );

    $p2p_redis->zadd('P2P::USERS_ONLINE', time() - 91, 'CR001::za');
    $emitted_events = {};
    $daemon->on_sec;

    cmp_deeply(
        $emitted_events,
        {
            p2p_advertiser_online_status => bag({
                    client_loginid => 'CR001',
                },
            ),
        },
        'advertiser goes offline'
    );

    $p2p_redis->zadd('P2P::USERS_ONLINE', time(), 'CR004::pt');
    $emitted_events = {};
    $daemon->on_sec;

    cmp_deeply(
        $emitted_events,
        {
            p2p_advertiser_online_status => bag({
                    client_loginid => 'CR004',
                },
            ),
        },
        'advertiser comes online'
    );

    $emitted_events = {};
    $daemon->on_sec;
    cmp_deeply($emitted_events, {}, 'nothing happens');

};

subtest 'advert subscriptions' => sub {
    clear_redis();
    $emitted_events = {};
    my $daemon = BOM::User::Script::P2PDaemon->new;

    # channel format is advertiser_id::account_id::loginid::advert_id
    for my $channel (
        'P2P::ADVERT::101::201::CR001::1',   'P2P::ADVERT::101::201::CR001::ALL',
        'P2P::ADVERT::102::202::CR002::ALL', 'P2P::ADVERT::103::203::CR003::ALL'
        )
    {
        $p2p_redis->subscribe($channel, sub { });
    }
    $p2p_redis->get_all_replies;

    $daemon->on_sec;

    my $msg = Test::MockObject->new();
    my $tx_channel;
    $msg->mock(channel => sub { $tx_channel });

    for my $tx ('TXNUPDATE::transaction_201', 'TXNUPDATE::transaction_202', 'TXNUPDATE::transaction_204') {
        $tx_channel = $tx;
        $daemon->on_transaction($msg);
    }

    cmp_deeply(
        $emitted_events,
        {
            p2p_adverts_updated => bag({
                    advertiser_id => 101,
                    channels      => bag('P2P::ADVERT::101::201::CR001::ALL', 'P2P::ADVERT::101::201::CR001::1')
                },
                {
                    advertiser_id => 102,
                    channels      => bag('P2P::ADVERT::102::202::CR002::ALL')})
        },
        'expected p2p_adverts_updated events emitted'
    );

    $p2p_redis->unsubscribe;
    $p2p_redis->get_all_replies;
};

subtest 'order reviews ending' => sub {
    clear_redis();
    $emitted_events = {};

    $p2p_config->review_period(1);    # setting is hours
    my $threshold = time - 3600 - 5;

    my $daemon = BOM::User::Script::P2PDaemon->new;

    my @items = (
        time()         => '1|CR001',
        $threshold + 1 => '2|CR002',
        $threshold     => '3|CR003',
        $threshold - 1 => '4|CR004',
    );

    $p2p_redis->zadd('P2P::ORDER::REVIEWABLE_START_AT', @items);

    $daemon->on_sec;

    cmp_deeply(
        $emitted_events,
        {
            p2p_order_updated => bag({
                    order_id       => 3,
                    client_loginid => 'CR003',
                    self_only      => 1,
                },
                {
                    order_id       => 4,
                    client_loginid => 'CR004',
                    self_only      => 1,
                },
            )
        },
        'expected p2p_order_updated events emitted'
    );

    cmp_deeply($p2p_redis->zrange('P2P::ORDER::REVIEWABLE_START_AT', 0, -1), bag('1|CR001', '2|CR002'), 'processed items removed');
};

subtest 'verification events' => sub {
    clear_redis();
    $emitted_events = {};

    my $daemon = BOM::User::Script::P2PDaemon->new;

    my @items = (
        time() - 1 => 'REQUEST_BLOCK|1|CR001',
        time() - 1 => 'TOKEN_VALID|2|CR002',
        time() - 1 => 'LOCKOUT|3|CR003',
        time() - 1 => 'XXX|4|CR004',
        time()     => 'REQUEST_BLOCK|5|CR005',
        time()     => 'TOKEN_VALID|6|CR006',
        time()     => 'LOCKOUT|7|CR007',
        time()     => 'XXX|8|CR008',
        time() + 1 => 'REQUEST_BLOCK|9|CR009',
        time() + 1 => 'TOKEN_VALID|10|CR0010',
        time() + 1 => 'LOCKOUT|11|CR0011',
        time() + 1 => 'XXX|12|CR0012',
    );

    $p2p_redis->zadd('P2P::ORDER::VERIFICATION_EVENT', @items);

    $daemon->on_sec;

    cmp_deeply(
        $emitted_events,
        {
            p2p_order_updated => bag({
                    order_id       => 1,
                    client_loginid => 'CR001',
                    self_only      => 1,
                },
                {
                    order_id       => 2,
                    client_loginid => 'CR002',
                    self_only      => 0,
                },
                {
                    order_id       => 3,
                    client_loginid => 'CR003',
                    self_only      => 0,
                },
                {
                    order_id       => 5,
                    client_loginid => 'CR005',
                    self_only      => 1,
                },
                {
                    order_id       => 6,
                    client_loginid => 'CR006',
                    self_only      => 0,
                },
                {
                    order_id       => 7,
                    client_loginid => 'CR007',
                    self_only      => 0,
                },
            )
        },
        'expected p2p_order_updated events emitted'
    );

    cmp_deeply(
        $p2p_redis->zrange('P2P::ORDER::VERIFICATION_EVENT', 0, -1),
        bag('REQUEST_BLOCK|9|CR009', 'TOKEN_VALID|10|CR0010', 'LOCKOUT|11|CR0011', 'XXX|12|CR0012'),
        'processed items removed'
    );

};

subtest 'update local currencies' => sub {
    $emitted_events = {};
    BOM::User::Script::P2PDaemon->new->on_min;

    cmp_deeply($emitted_events->{p2p_update_local_currencies}, [{}], 'p2p_update_local_currencies event emitted');
};

done_testing();
