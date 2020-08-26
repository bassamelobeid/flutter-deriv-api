use strict;
use warnings;

use Test::MockTime qw(set_fixed_time);
use Test::More;
use Test::Deep;
use Test::Warn;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use Test::Fatal;
use Test::Exception;
use Guard;

BOM::Config::Runtime->instance->app_config->payments->p2p->limits->count_per_day_per_client(10);
BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();
BOM::Test::Helper::P2P::purge_redis();    # can fail in circle-ci without this

my ($advertiser, $client, $advert, $order);

my $default_stats = {
    'buy_orders_count'   => 0,
    'sell_orders_count'  => 0,
    'total_orders_count' => 0,
    'cancel_time_avg'    => undef,
    'release_time_avg'   => undef,
    'completion_rate'    => undef,
};

my $stats_cli = {$default_stats->%*};
my $stats_adv = {$default_stats->%*};

subtest 'errors' => sub {
    my $cli = BOM::Test::Helper::Client::create_client();

    cmp_deeply(exception { $cli->p2p_advertiser_stats(id => -1) }, {error_code => 'AdvertiserNotFound'}, 'Advertiser not found');

    cmp_deeply(exception { $cli->p2p_advertiser_stats() }, {error_code => 'AdvertiserNotRegistered'}, 'Client not advertiser');

    cmp_deeply($cli->_p2p_advertiser_stats_get($cli->loginid, 30), $default_stats, 'stats for non advertiser');
};

subtest 'sell ads' => sub {

    ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'stats for new advertiser');

    set_fixed_time('2000-01-01 00:00:00', '%Y-%m-%d %H:%M:%S');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1,
        balance   => 100
    );
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'advertiser stats after order created');
    cmp_deeply($client->p2p_advertiser_stats,     $stats_cli, 'client stats after order created');

    $client->p2p_order_confirm(id => $order->{id});
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'advertiser stats after buyer created');
    cmp_deeply($client->p2p_advertiser_stats,     $stats_cli, 'client stats after buyer confirm');

    set_fixed_time('2000-01-01 00:01:40', '%Y-%m-%d %H:%M:%S');    # +40s
    $advertiser->p2p_order_confirm(id => $order->{id});
    $stats_adv->{total_orders_count} = ++$stats_cli->{total_orders_count};
    $stats_adv->{sell_orders_count}  = ++$stats_cli->{buy_orders_count};
    $stats_adv->{release_time_avg}   = 100;
    $stats_cli->{completion_rate}    = '100.00';
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'advertiser stats after seller confirm');
    cmp_deeply($client->p2p_advertiser_stats,     $stats_cli, 'client stats after seller confirm');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'advertiser stats after order created');
    cmp_deeply($client->p2p_advertiser_stats,     $stats_cli, 'client stats after order created');

    set_fixed_time('2000-01-01 00:02:00', '%Y-%m-%d %H:%M:%S');    # +20s
    $client->p2p_order_cancel(id => $order->{id});
    $stats_cli->{cancel_time_avg} = 20;
    $stats_cli->{completion_rate} = '50.00';
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'advertiser stats after order cancelled');
    cmp_deeply($client->p2p_advertiser_stats,     $stats_cli, 'client stats after order cancelled');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    set_fixed_time('2000-01-01 00:02:30', '%Y-%m-%d %H:%M:%S');    # +30s
    $client->p2p_order_cancel(id => $order->{id});
    $stats_cli->{cancel_time_avg} = 25;
    $stats_cli->{completion_rate} = '33.33';
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'advertiser stats after 2nd order cancelled');
    cmp_deeply($client->p2p_advertiser_stats,     $stats_cli, 'client stats after 2nd order cancelled');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    set_fixed_time('2000-01-01 00:04:30', '%Y-%m-%d %H:%M:%S');    # +2h
    $client->p2p_expire_order(id => $order->{id});
    $stats_cli->{completion_rate} = '25.00';
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'advertiser stats after order expired');
    cmp_deeply($client->p2p_advertiser_stats,     $stats_cli, 'client stats after order expired');

    set_fixed_time('2000-03-01 00:00:00', '%Y-%m-%d %H:%M:%S');    # +2 month
    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 2
    );
    $client->p2p_order_confirm(id => $order->{id});
    set_fixed_time('2000-03-01 00:00:05', '%Y-%m-%d %H:%M:%S');    # +5s
    $advertiser->p2p_order_confirm(id => $order->{id});
    $stats_cli->{total_orders_count} = ++$stats_adv->{total_orders_count};
    $stats_cli->{buy_orders_count}   = $stats_adv->{sell_orders_count} = 1;
    $stats_adv->{release_time_avg}   = 5;
    $stats_cli->{cancel_time_avg}    = undef;
    $stats_cli->{completion_rate}    = '100.00';
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'advertiser stats in future');
    cmp_deeply($client->p2p_advertiser_stats,     $stats_cli, 'client stats in future');
};

subtest 'buy ads' => sub {

    ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        client => $advertiser,
        type   => 'buy'
    );
    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'advertiser stats after order created');
    cmp_deeply($client->p2p_advertiser_stats,     $stats_cli, 'client stats after order created');

    $advertiser->p2p_order_confirm(id => $order->{id});
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'advertiser stats after buyer confirm');
    cmp_deeply($client->p2p_advertiser_stats,     $stats_cli, 'client stats after buyer confirm');

    set_fixed_time('2000-03-01 00:01:00', '%Y-%m-%d %H:%M:%S');    # +55s
    $client->p2p_order_confirm(id => $order->{id});
    $stats_cli->{total_orders_count} = ++$stats_adv->{total_orders_count};
    $stats_cli->{sell_orders_count}  = ++$stats_adv->{buy_orders_count};
    $stats_cli->{release_time_avg}   = 55;
    $stats_adv->{completion_rate}    = '100.00';
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'advertiser stats after seller confirm');
    cmp_deeply($client->p2p_advertiser_stats,     $stats_cli, 'client stats after seller confirm');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    set_fixed_time('2000-03-01 00:01:10', '%Y-%m-%d %H:%M:%S');    # +10s
    $advertiser->p2p_order_cancel(id => $order->{id});
    $stats_adv->{cancel_time_avg} = 10;
    $stats_adv->{completion_rate} = '50.00';
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'advertiser stats after order cancelled');
    cmp_deeply($client->p2p_advertiser_stats,     $stats_cli, 'client stats after order cancelled');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    $advertiser->p2p_expire_order(id => $order->{id});
    $stats_adv->{completion_rate} = '33.33';
    cmp_deeply($advertiser->p2p_advertiser_stats, $stats_adv, 'advertiser stats after order expired');
    cmp_deeply($client->p2p_advertiser_stats,     $stats_cli, 'client stats after order expired');
};

BOM::Test::Helper::P2P::reset_escrow();

done_testing();
