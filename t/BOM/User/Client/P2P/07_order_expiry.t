use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Fatal;
use Test::Deep;
use Guard;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use BOM::Config::Redis;

BOM::Test::Helper::P2P::bypass_sendbird();
my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
my $redis  = BOM::Config::Redis->redis_p2p();

my $expire_key  = 'P2P::ORDER::EXPIRES_AT';
my $timeout_key = 'P2P::ORDER::TIMEDOUT_AT';

my $original_expiry  = $config->order_timeout;
my $original_timeout = $config->refund_timeout;

scope_guard {
    $config->order_timeout($original_expiry);
    $config->refund_timeout($original_timeout);
};

$config->order_timeout(7200);    #seconds
$config->refund_timeout(30);     #days

my @emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => sub { push @emitted_events, \@_ });

my @test_cases = (
    #Buy orders:
    {
        test_name          => 'Buy order in pending state not ready to expire',
        type               => 'sell',
        amount             => 100,
        error              => undef,
        init_status        => 'pending',
        client_balance     => 0,
        advertiser_balance => 100,
        escrow             => {
            before => 100,
            after  => 100
        },
        client => {
            before => 0,
            after  => 0
        },
        advertiser => {
            before => 0,
            after  => 0
        },
        status     => 'pending',
        expiry     => '2 minute',
        expire_key => 1,
    },
    {
        test_name          => 'Buy order in pending state at expiry time',
        type               => 'sell',
        amount             => 100,
        error              => undef,
        init_status        => 'pending',
        client_balance     => 0,
        advertiser_balance => 100,
        escrow             => {
            before => 100,
            after  => 0
        },
        client => {
            before => 0,
            after  => 0
        },
        advertiser => {
            before => 0,
            after  => 100
        },
        status => 'refunded',
        expiry => '0 minute',
        event  => 1,
    },
    {
        test_name          => 'Buy in pending state expired ages ago',
        type               => 'sell',
        amount             => 100,
        error              => undef,
        init_status        => 'pending',
        client_balance     => 0,
        advertiser_balance => 100,
        escrow             => {
            before => 100,
            after  => 0
        },
        client => {
            before => 0,
            after  => 0
        },
        advertiser => {
            before => 0,
            after  => 100
        },
        status => 'refunded',
        expiry => '-100 day',
        event  => 1,
    },
    {
        test_name          => 'Buy order at buyer-confirmed state not ready to expire',
        type               => 'sell',
        amount             => 100,
        error              => undef,
        init_status        => 'buyer-confirmed',
        client_balance     => 0,
        advertiser_balance => 100,
        escrow             => {
            before => 100,
            after  => 100
        },
        client => {
            before => 0,
            after  => 0
        },
        advertiser => {
            before => 0,
            after  => 0
        },
        status     => 'buyer-confirmed',
        expiry     => '2 minute',
        expire_key => 1,
    },
    {
        test_name          => 'Buy order at buyer-confirmed state at expiry time',
        type               => 'sell',
        amount             => 100,
        error              => undef,
        init_status        => 'buyer-confirmed',
        client_balance     => 0,
        advertiser_balance => 100,
        escrow             => {
            before => 100,
            after  => 100
        },
        client => {
            before => 0,
            after  => 0
        },
        advertiser => {
            before => 0,
            after  => 0
        },
        status      => 'timed-out',
        expiry      => '0 minute',
        timeout_key => 1,
        event       => 1,
    },

    # Sell orders
    {
        test_name          => 'Sell order expire at pending state',
        type               => 'buy',
        amount             => 100,
        error              => undef,
        init_status        => 'pending',
        client_balance     => 100,
        advertiser_balance => 0,
        escrow             => {
            before => 100,
            after  => 0
        },
        client => {
            before => 0,
            after  => 100
        },
        advertiser => {
            before => 0,
            after  => 0
        },
        status => 'refunded',
        event  => 1,
    },
    {
        test_name          => 'Sell order expire at buyer-confirmed state',
        type               => 'buy',
        amount             => 100,
        error              => undef,
        init_status        => 'buyer-confirmed',
        client_balance     => 100,
        advertiser_balance => 0,
        escrow             => {
            before => 100,
            after  => 100
        },
        client => {
            before => 0,
            after  => 0
        },
        advertiser => {
            before => 0,
            after  => 0
        },
        status      => 'timed-out',
        timeout_key => 1,
        event       => 1,
    },
);

for my $status (qw(cancelled completed disputed dispute-completed dispute-refunded)) {
    for my $type (qw(sell buy)) {
        push @test_cases,
            {
            test_name          => "Order expiration at $status status for $type order",
            type               => $type,
            amount             => 100,
            error              => undef,
            init_status        => $status,
            client_balance     => $type eq 'sell' ? 0   : 100,
            advertiser_balance => $type eq 'sell' ? 100 : 0,
            escrow             => {
                before => 100,
                after  => 100
            },
            client => {
                before => 0,
                after  => 0
            },
            advertiser => {
                before => 0,
                after  => 0
            },
            status => $status,
            };
    }

}

for my $test_case (@test_cases) {
    subtest $test_case->{test_name} => sub {
        my $amount = $test_case->{amount};

        my $escrow = BOM::Test::Helper::P2P::create_escrow();
        my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
            amount  => $amount,
            type    => $test_case->{type},
            balance => $test_case->{advertiser_balance},
        );
        my ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert_info->{id},
            amount    => $amount,
            balance   => $test_case->{client_balance},
        );

        cmp_ok($escrow->account->balance,     '==', $test_case->{escrow}{before},     'Escrow balance is correct');
        cmp_ok($advertiser->account->balance, '==', $test_case->{advertiser}{before}, 'advertiser balance is correct');
        cmp_ok($client->account->balance,     '==', $test_case->{client}{before},     'Client balance is correct');

        BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, $test_case->{init_status});
        BOM::Test::Helper::P2P::expire_order($client, $order->{id}, $test_case->{expiry});
        @emitted_events = ();

        my $err = exception {
            $client->p2p_expire_order(
                id     => $order->{id},
                source => 5,
                staff  => 'AUTOEXPIRY',
            );
        };
        is($err->{error_code}, $test_case->{error}, 'Got expected error behavior');

        cmp_ok($escrow->account->balance,     '==', $test_case->{escrow}{after},     'Escrow balance is correct');
        cmp_ok($advertiser->account->balance, '==', $test_case->{advertiser}{after}, 'advertiser balance is correct');
        cmp_ok($client->account->balance,     '==', $test_case->{client}{after},     'Client balance is correct');

        my $order_data = $client->p2p_order_info(id => $order->{id}) // die;

        is($order_data->{status}, $test_case->{status}, 'Status for new order is correct');
        cmp_ok($order_data->{amount}, '==', $amount, 'Amount for new order is correct');
        is($order_data->{advert_details}{type}, $test_case->{type}, 'Description for new order is correct');

        my $redis_item = join '|', $order->{id}, $client->loginid;
        is($redis->zscore($expire_key,  $redis_item) ? 1 : undef, $test_case->{expire_key},  'expire key existence');
        is($redis->zscore($timeout_key, $redis_item) ? 1 : undef, $test_case->{timeout_key}, 'timeout key existence');

        if ($test_case->{event}) {
            my @expected_events = ([
                    'p2p_order_updated',
                    {
                        client_loginid => $client->loginid,
                        order_id       => $order->{id},
                        order_event    => 'expired',
                    }
                ],
            );
            if ($test_case->{status} eq 'refunded') {
                push @expected_events,
                    [
                    'p2p_advertiser_updated',
                    {
                        client_loginid => $client->loginid,
                    }
                    ],
                    [
                    'p2p_advertiser_updated',
                    {
                        client_loginid => $advertiser->loginid,
                    }];
            }

            cmp_deeply(\@emitted_events, bag(@expected_events), 'expected event emitted');
        } else {
            ok !@emitted_events, 'no events emitted';
        }

        BOM::Test::Helper::P2P::reset_escrow();
    };
}

subtest 'timed out orders' => sub {
    BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert;
    my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});
    my $redis_item = join '|', $order->{id}, $client->loginid;

    ok $redis->zscore($expire_key, $redis_item), 'redis expire item present';
    BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'buyer-confirmed');
    BOM::Test::Helper::P2P::expire_order($client, $order->{id}, '0 hour');

    @emitted_events = ();

    is $client->p2p_expire_order(
        id     => $order->{id},
        source => 5,
        staff  => 'AUTOEXPIRY'
        ),
        'timed-out', 'status changed to timed-out';

    ok !$redis->zscore($expire_key, $redis_item), 'redis expire item removed';
    ok $redis->zscore($timeout_key, $redis_item), 'redis timeout item present';

    cmp_deeply(
        \@emitted_events,
        [[
                'p2p_order_updated',
                {
                    client_loginid => $client->loginid,
                    order_id       => $order->{id},
                    order_event    => 'expired',
                }
            ],
        ],
        'expected events emitted'
    );

    BOM::Test::Helper::P2P::expire_order($client, $order->{id}, '-28 day');

    @emitted_events = ();
    ok !$client->p2p_expire_order(
        id     => $order->{id},
        source => 5,
        staff  => 'AUTOEXPIRY'
        ),
        'no status change for early expiry';
    ok !$redis->zscore($expire_key, $redis_item), 'redis expire item still removed';
    ok $redis->zscore($timeout_key, $redis_item), 'redis timeout item still present';

    BOM::Test::Helper::P2P::expire_order($client, $order->{id}, '-30 day');
    is $client->p2p_expire_order(
        id     => $order->{id},
        source => 5,
        staff  => 'AUTOEXPIRY'
        ),
        'refunded', 'status changes to refunded';
    ok !$redis->zscore($expire_key,  $redis_item), 'redis expire item still removed';
    ok !$redis->zscore($timeout_key, $redis_item), 'redis timeout item removed';

    cmp_deeply(
        \@emitted_events,
        bag([
                'p2p_order_updated',
                {
                    client_loginid => $client->loginid,
                    order_id       => $order->{id},
                    order_event    => 'timeout_refund',
                }
            ],
            [
                'p2p_advertiser_updated',
                {
                    client_loginid => $client->loginid,
                }
            ],
            [
                'p2p_advertiser_updated',
                {
                    client_loginid => $advertiser->loginid,
                }
            ],
        ),
        'expected events emitted'
    );

    # add an old key which would not usually be there
    $redis->zadd($timeout_key, Date::Utility->new->minus_time_interval('30d')->epoch, $redis_item);
    ok !$client->p2p_expire_order(
        id     => $order->{id},
        source => 5,
        staff  => 'AUTOEXPIRY'
        ),
        'no status change for repeat timeout';
    ok !$redis->zscore($timeout_key, $redis_item), 'redis timeout item removed for repeat timeout';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'repeat expiry' => sub {
    BOM::Test::Helper::P2P::create_escrow();

    subtest 'refunded order' => sub {
        my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert;
        my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});
        my $redis_item = join '|', $order->{id}, $client->loginid;

        BOM::Test::Helper::P2P::expire_order($client, $order->{id}, '0 hour');
        is $client->p2p_expire_order(
            id     => $order->{id},
            source => 5,
            staff  => 'AUTOEXPIRY'
            ),
            'refunded', 'status is now refunded';

        $redis->zadd($expire_key, Date::Utility->new->minus_time_interval('1d')->epoch, $redis_item);
        ok !$client->p2p_expire_order(
            id     => $order->{id},
            source => 5,
            staff  => 'AUTOEXPIRY'
            ),
            'no status change for repeat expiry';
        ok !$redis->zscore($expire_key, $redis_item), 'redis expiry item removed for repeat expiry';
    };

    subtest 'timed-out order' => sub {
        my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert;
        my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});
        my $redis_item = join '|', $order->{id}, $client->loginid;

        BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'buyer-confirmed');
        BOM::Test::Helper::P2P::expire_order($client, $order->{id}, '0 hour');
        is $client->p2p_expire_order(
            id     => $order->{id},
            source => 5,
            staff  => 'AUTOEXPIRY'
            ),
            'timed-out', 'status is now timed-out';

        $redis->zadd($expire_key, Date::Utility->new->minus_time_interval('1d')->epoch, $redis_item);
        ok !$client->p2p_expire_order(
            id     => $order->{id},
            source => 5,
            staff  => 'AUTOEXPIRY'
            ),
            'no status change for repeat expiry';
        ok !$redis->zscore($expire_key, $redis_item), 'redis expiry item removed for repeat expiry';
    };

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'errors' => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert;
    my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});

    my $exception = exception {
        $client->p2p_expire_order();
    };
    like $exception, qr/No id provided to p2p_expire_order/, 'Bad params';

    $exception = exception {
        $client->p2p_expire_order(
            id     => $order->{id} * -1,
            source => 5,
            staff  => 'AUTOEXPIRY',
        );
    };
    like $exception, qr/Invalid order provided to p2p_expire_order/, 'Invalid order id';

    # Escrow not found
    my $mock = Test::MockModule->new('BOM::User::Client');
    $mock->mock(p2p_escrow => sub { });

    BOM::Test::Helper::P2P::ready_to_refund($client, $order->{id});
    $exception = exception {
        $client->p2p_expire_order(
            id     => $order->{id},
            source => 5,
            staff  => 'AUTOEXPIRY',
        );
    };

    like $exception, qr/P2P escrow not found/, 'P2P escrow not found';

    $mock->unmock_all;

    BOM::Test::Helper::P2P::reset_escrow();
};

done_testing();
