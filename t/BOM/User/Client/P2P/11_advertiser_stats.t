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

my ($advertiser, $client, $advert, $order);

my %default_stats = (
    'buy_orders_count'      => 0,
    'sell_orders_count'     => 0,
    'total_orders_count'    => 0,
    'cancel_time_avg'       => undef,
    'release_time_avg'      => undef,
    'total_completion_rate' => undef,
    'buy_completion_rate'   => undef,
    'sell_completion_rate'  => undef,
    'basic_verification'    => 0,
    'full_verification'     => 0,
);
my $stats_cli  = {%default_stats};
my $stats_adv  = {%default_stats};

subtest 'errors' => sub {
    my $cli = BOM::Test::Helper::Client::create_client();

    cmp_deeply(exception { $cli->p2p_advertiser_stats(id => -1) }, {error_code => 'AdvertiserNotFound'}, 'Advertiser not found');

    cmp_deeply(exception { $cli->p2p_advertiser_stats() }, {error_code => 'AdvertiserNotRegistered'}, 'Client not advertiser');

    cmp_deeply($cli->_p2p_advertiser_stats_get($cli->loginid, 30), {%default_stats}, 'stats for non advertiser');
};

subtest 'verification' => sub {
    ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    check_stats($advertiser, $stats_adv, 'stats for new advertiser');

    $advertiser->status->set('age_verification', 'system', 'testing');
    $stats_adv->{basic_verification} = 1;
    check_stats($advertiser, $stats_adv, 'age verified sets basic verification');

    $advertiser->set_authentication('ID_ONLINE', {status => 'pass'});
    $stats_adv->{full_verification} = 1;
    check_stats($advertiser, $stats_adv, 'POA sets basic verification');
};

subtest 'sell ads' => sub {
    set_fixed_time('2000-01-01 00:00:00', '%Y-%m-%d %H:%M:%S');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1,
        balance   => 100
    );
    check_stats($advertiser, $stats_adv, 'advertiser stats after order created');
    check_stats($client,     $stats_cli, 'client stats after order created');

    $client->p2p_order_confirm(id => $order->{id});
    check_stats($advertiser, $stats_adv, 'advertiser stats after buyer confim');
    check_stats($client,     $stats_cli, 'client stats after buyer confirm');

    set_fixed_time('2000-01-01 00:01:40', '%Y-%m-%d %H:%M:%S');    # +40s
    $advertiser->p2p_order_confirm(id => $order->{id});
    $stats_adv->{total_orders_count}   = ++$stats_cli->{total_orders_count};
    $stats_adv->{sell_orders_count}    = ++$stats_cli->{buy_orders_count};
    $stats_adv->{release_time_avg}     = 100;
    $stats_adv->{sell_completion_rate} = $stats_adv->{total_completion_rate} = '100.00';
    $stats_cli->{buy_completion_rate}  = $stats_cli->{total_completion_rate} = '100.00';
    check_stats($advertiser, $stats_adv, 'advertiser stats after seller confim');
    check_stats($client,     $stats_cli, 'client stats after seller confirm');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    check_stats($advertiser, $stats_adv, 'advertiser stats after order 2 created');
    check_stats($client,     $stats_cli, 'client stats after order 2 created');

    set_fixed_time('2000-01-01 00:02:00', '%Y-%m-%d %H:%M:%S');    # +20s
    $client->p2p_order_cancel(id => $order->{id});
    $stats_cli->{cancel_time_avg}     = 20;
    $stats_cli->{buy_completion_rate} = $stats_cli->{total_completion_rate} = '50.00';
    check_stats($advertiser, $stats_adv, 'advertiser stats after order cancelled');
    check_stats($client,     $stats_cli, 'client stats after order cancelled');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    set_fixed_time('2000-01-01 00:02:30', '%Y-%m-%d %H:%M:%S');    # +30s
    $client->p2p_order_cancel(id => $order->{id});
    $stats_cli->{cancel_time_avg}     = 25;
    $stats_cli->{buy_completion_rate} = $stats_cli->{total_completion_rate} = '33.33';
    check_stats($advertiser, $stats_adv, 'advertiser stats after 2nd order cancelled');
    check_stats($client,     $stats_cli, 'client stats after 2nd order cancelled');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    set_fixed_time('2000-01-01 00:04:30', '%Y-%m-%d %H:%M:%S');    # +2h
    BOM::Test::Helper::P2P::expire_order($client, $order->{id});
    $client->p2p_expire_order(id => $order->{id});
    $stats_cli->{buy_completion_rate} = $stats_cli->{total_completion_rate} = '25.00';
    check_stats($advertiser, $stats_adv, 'advertiser stats after order expired');
    check_stats($client,     $stats_cli, 'client stats after order expired');

    set_fixed_time('2000-03-01 00:00:00', '%Y-%m-%d %H:%M:%S');    # +2 month
    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 2
    );
    $client->p2p_order_confirm(id => $order->{id});
    set_fixed_time('2000-03-01 00:00:05', '%Y-%m-%d %H:%M:%S');    # +5s
    $advertiser->p2p_order_confirm(id => $order->{id});
    $stats_cli->{total_orders_count}  = ++$stats_adv->{total_orders_count};
    $stats_cli->{buy_orders_count}    = $stats_adv->{sell_orders_count} = 1;
    $stats_adv->{release_time_avg}    = 5;
    $stats_cli->{cancel_time_avg}     = undef;
    $stats_cli->{buy_completion_rate} = $stats_cli->{total_completion_rate} = '100.00';
    check_stats($advertiser, $stats_adv, 'advertiser stats in future');
    check_stats($client,     $stats_cli, 'client stats in future');
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
    check_stats($advertiser, $stats_adv, 'advertiser stats after order created');
    check_stats($client,     $stats_cli, 'client stats after order created');

    $advertiser->p2p_order_confirm(id => $order->{id});
    check_stats($advertiser, $stats_adv, 'advertiser stats after buyer confirm');
    check_stats($client,     $stats_cli, 'client stats after buyer confirm');

    set_fixed_time('2000-03-01 00:01:00', '%Y-%m-%d %H:%M:%S');    # +55s
    $client->p2p_order_confirm(id => $order->{id});
    $stats_cli->{total_orders_count}   = ++$stats_adv->{total_orders_count};
    $stats_cli->{sell_orders_count}    = ++$stats_adv->{buy_orders_count};
    $stats_cli->{release_time_avg}     = 55;
    $stats_cli->{sell_completion_rate} = $stats_cli->{total_completion_rate} = '100.00';
    $stats_adv->{buy_completion_rate}  = $stats_adv->{total_completion_rate} = '100.00';
    check_stats($advertiser, $stats_adv, 'advertiser stats after seller confirm');
    check_stats($client,     $stats_cli, 'client stats after seller confirm');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    set_fixed_time('2000-03-01 00:01:10', '%Y-%m-%d %H:%M:%S');    # +10s
    $advertiser->p2p_order_cancel(id => $order->{id});
    $stats_adv->{cancel_time_avg}       = 10;
    $stats_adv->{total_completion_rate} = '66.67';
    $stats_adv->{buy_completion_rate}   = '50.00';
    check_stats($advertiser, $stats_adv, 'advertiser stats after order cancelled');
    check_stats($client,     $stats_cli, 'client stats after order cancelled');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    BOM::Test::Helper::P2P::expire_order($advertiser, $order->{id});
    $advertiser->p2p_expire_order(id => $order->{id});
    $stats_adv->{total_completion_rate} = '50.00';
    $stats_adv->{buy_completion_rate}   = '33.33';
    check_stats($advertiser, $stats_adv, 'advertiser stats after order expired');
    check_stats($client,     $stats_cli, 'client stats after order expired');
};

subtest 'different advertiser' => sub {
    my $advertiser2 = BOM::Test::Helper::P2P::create_advertiser;
    my $res         = $advertiser->p2p_advertiser_stats(id => $advertiser2->p2p_advertiser_info->{id});
    cmp_deeply($res, superhashof(\%default_stats), 'stats are for new advertiser');
};

BOM::Test::Helper::P2P::reset_escrow();

done_testing();

sub check_stats {
    my ($client, $expected, $desc) = @_;
    cmp_deeply($client->p2p_advertiser_stats, $expected,              "$desc (p2p_advertiser_stats)");
    cmp_deeply($client->p2p_advertiser_info,  superhashof($expected), "$desc (p2p_advertiser_info)");
}
