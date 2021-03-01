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
use Test::Fatal;
use Test::Exception;
use Date::Utility;
use Test::MockModule;

BOM::Config::Runtime->instance->app_config->payments->p2p->limits->count_per_day_per_client(10);
BOM::Config::Runtime->instance->app_config->payments->p2p->cancellation_grace_period(10);
BOM::Config::Runtime->instance->app_config->payments->p2p->cancellation_barring->count(10);
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
my $stats_cli = {%default_stats};
my $stats_adv = {%default_stats};

my $dt = Date::Utility->new('2000-01-01T00:00:00Z');

sub tt_secs {
    my $secs = shift;
    $dt = $dt->plus_time_interval($secs . 's');
    set_fixed_time($dt->iso8601);
    BOM::Test::Helper::P2P::adjust_completion_rates($secs);
}

my $emit_args;
my $emit_mock   = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $client_mock = Test::MockModule->new('BOM::User::Client');
$emit_mock->mock(
    'emit',
    sub {
        $emit_args->{$_[0]} = $_[1];
        return $emit_mock->original('emit')->(@_);
    });

$client_mock->mock(
    'p2p_resolve_order_dispute',
    sub {
        my (undef, %args) = @_;
        my $expected_event = join('_', 'dispute', $args{fraud} ? 'fraud' : (), $args{action});
        my $response       = $client_mock->original('p2p_resolve_order_dispute')->(@_);
        is $emit_args->{p2p_order_updated}->{order_event}, $expected_event, 'order event is correct';
        return $response;
    });

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
    tt_secs(0);

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

    tt_secs(1000);
    $advertiser->p2p_order_confirm(id => $order->{id});
    $stats_adv->{total_orders_count}   = ++$stats_cli->{total_orders_count};
    $stats_adv->{sell_orders_count}    = ++$stats_cli->{buy_orders_count};
    $stats_adv->{release_time_avg}     = 1000;
    $stats_adv->{sell_completion_rate} = $stats_adv->{total_completion_rate} = '100.0';
    $stats_cli->{buy_completion_rate}  = $stats_cli->{total_completion_rate} = '100.0';
    check_stats($advertiser, $stats_adv, 'advertiser stats after seller confim');
    check_stats($client,     $stats_cli, 'client stats after seller confirm');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    check_stats($advertiser, $stats_adv, 'advertiser stats after order 2 created');
    check_stats($client,     $stats_cli, 'client stats after order 2 created');

    tt_secs(800);
    $client->p2p_order_cancel(id => $order->{id});
    $stats_cli->{cancel_time_avg}     = 800;
    $stats_cli->{buy_completion_rate} = $stats_cli->{total_completion_rate} = '50.0';
    check_stats($advertiser, $stats_adv, 'advertiser stats after order cancelled');
    check_stats($client,     $stats_cli, 'client stats after order cancelled');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    tt_secs(1400);
    $client->p2p_order_cancel(id => $order->{id});
    $stats_cli->{cancel_time_avg}     = 1100;
    $stats_cli->{buy_completion_rate} = $stats_cli->{total_completion_rate} = '33.3';
    check_stats($advertiser, $stats_adv, 'advertiser stats after 2nd order cancelled');
    check_stats($client,     $stats_cli, 'client stats after 2nd order cancelled');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );

    tt_secs(2 * 60 * 60);    #+2h
    BOM::Test::Helper::P2P::expire_order($client, $order->{id});
    $client->p2p_expire_order(id => $order->{id});
    $stats_cli->{buy_completion_rate} = $stats_cli->{total_completion_rate} = '25.0';
    check_stats($advertiser, $stats_adv, 'advertiser stats after order expired');
    check_stats($client,     $stats_cli, 'client stats after order expired');

    tt_secs(60 * 24 * 60 * 60);    #+60d
    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 2
    );
    $client->p2p_order_confirm(id => $order->{id});
    tt_secs(5);
    $advertiser->p2p_order_confirm(id => $order->{id});
    $stats_cli->{total_orders_count}  = ++$stats_adv->{total_orders_count};
    $stats_cli->{buy_orders_count}    = $stats_adv->{sell_orders_count} = 1;
    $stats_adv->{release_time_avg}    = 5;
    $stats_cli->{cancel_time_avg}     = undef;
    $stats_cli->{buy_completion_rate} = $stats_cli->{total_completion_rate} = '100.0';
    check_stats($advertiser, $stats_adv, 'advertiser stats in future');
    check_stats($client,     $stats_cli, 'client stats in future');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );
    tt_secs(5);
    $client->p2p_order_cancel(id => $order->{id});
    check_stats($advertiser, $stats_adv, 'cancel during grace period, advertiser stats unchanged');
    check_stats($client,     $stats_cli, 'cancel during grace period, client stats unchanged');
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

    tt_secs(1200);
    $client->p2p_order_confirm(id => $order->{id});
    $stats_cli->{total_orders_count}   = ++$stats_adv->{total_orders_count};
    $stats_cli->{sell_orders_count}    = ++$stats_adv->{buy_orders_count};
    $stats_cli->{release_time_avg}     = 1200;
    $stats_cli->{sell_completion_rate} = $stats_cli->{total_completion_rate} = '100.0';
    $stats_adv->{buy_completion_rate}  = $stats_adv->{total_completion_rate} = '100.0';
    check_stats($advertiser, $stats_adv, 'advertiser stats after seller confirm');
    check_stats($client,     $stats_cli, 'client stats after seller confirm');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );

    tt_secs(2000);
    $advertiser->p2p_order_cancel(id => $order->{id});
    $stats_adv->{cancel_time_avg}       = 2000;
    $stats_adv->{total_completion_rate} = '66.7';
    $stats_adv->{buy_completion_rate}   = '50.0';
    check_stats($advertiser, $stats_adv, 'advertiser stats after order cancelled');
    check_stats($client,     $stats_cli, 'client stats after order cancelled');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1
    );

    tt_secs(2 * 60 * 60);    #+2h
    BOM::Test::Helper::P2P::expire_order($advertiser, $order->{id});
    $advertiser->p2p_expire_order(id => $order->{id});
    $stats_adv->{total_completion_rate} = '50.0';
    $stats_adv->{buy_completion_rate}   = '33.3';
    check_stats($advertiser, $stats_adv, 'advertiser stats after order expired');
    check_stats($client,     $stats_cli, 'client stats after order expired');
};

subtest 'dispute resolution - fraud' => sub {
    my ($client, $advertiser, $advert, $order);
    my $stats_cli = {%default_stats};
    my $stats_adv = {%default_stats};

    subtest 'advertiser seller fraud' => sub {
        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
            type           => 'sell',
            client         => $advertiser,
            local_currency => 'aaa',
        );

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
            client    => $client,
        );

        BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
        $client->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'buyer_underpaid',
        );

        $client->p2p_resolve_order_dispute(
            id     => $order->{id},
            action => 'complete',
            staff  => 'me',
            fraud  => 1,
        );

        $stats_adv->{total_completion_rate} = $stats_adv->{sell_completion_rate} = '0.0';
        $stats_cli->{total_completion_rate} = $stats_cli->{buy_completion_rate}  = '100.0';
        $stats_adv->{sell_orders_count}     = 1;
        $stats_adv->{total_orders_count}    = 1;
        $stats_cli->{buy_orders_count}      = 1;
        $stats_cli->{total_orders_count}    = 1;
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };

    subtest 'advertiser buyer fraud' => sub {
        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
            type           => 'buy',
            client         => $advertiser,
            local_currency => 'aaa',
        );

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
            client    => $client,
        );

        BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
        $client->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'buyer_underpaid',
        );

        $client->p2p_resolve_order_dispute(
            id     => $order->{id},
            action => 'refund',
            staff  => 'me',
            fraud  => 1,
        );

        $stats_adv->{buy_completion_rate} = '0.0';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };

    subtest 'client seller fraud' => sub {
        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
            type           => 'buy',
            client         => $advertiser,
            local_currency => 'bbb',
        );

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
            client    => $client,
        );

        BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
        $client->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'buyer_underpaid',
        );

        $client->p2p_resolve_order_dispute(
            id     => $order->{id},
            action => 'complete',
            staff  => 'me',
            fraud  => 1,
        );

        $stats_adv->{buy_completion_rate}   = '50.0';
        $stats_adv->{total_completion_rate} = '33.3';
        $stats_adv->{buy_orders_count}      = 1;
        $stats_adv->{total_orders_count}    = 2;
        $stats_cli->{sell_orders_count}     = 1;
        $stats_cli->{total_orders_count}    = 2;
        $stats_cli->{sell_completion_rate}  = '0.0';
        $stats_cli->{total_completion_rate} = '50.0';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };

    subtest 'client buyer fraud' => sub {
        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
            type           => 'sell',
            client         => $advertiser,
            local_currency => 'bbb',
        );

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
            client    => $client,
        );

        BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
        $client->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'buyer_underpaid',
        );

        $client->p2p_resolve_order_dispute(
            id     => $order->{id},
            action => 'refund',
            staff  => 'me',
            fraud  => 1,
        );

        $stats_cli->{buy_completion_rate}   = '50.0';
        $stats_cli->{total_completion_rate} = '33.3';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };
};

subtest 'dispute resolution - no fraud' => sub {

    my ($client, $advertiser, $advert, $order);
    my $stats_cli = {%default_stats};
    my $stats_adv = {%default_stats};

    subtest 'sell ad complete' => sub {
        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
            type           => 'sell',
            client         => $advertiser,
            local_currency => 'ccc',
        );

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
            client    => $client,
        );

        BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
        $client->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'buyer_underpaid',
        );

        $client->p2p_resolve_order_dispute(
            id     => $order->{id},
            action => 'complete',
            staff  => 'me',
            fraud  => 0,
        );

        $stats_adv->{total_completion_rate} = $stats_adv->{sell_completion_rate} = '100.0';
        $stats_cli->{total_completion_rate} = $stats_cli->{buy_completion_rate}  = '100.0';
        $stats_adv->{sell_orders_count}     = $stats_adv->{total_orders_count}   = 1;
        $stats_cli->{buy_orders_count}      = $stats_cli->{total_orders_count}   = 1;
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };

    subtest 'buy ad refund' => sub {
        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
            type           => 'buy',
            client         => $advertiser,
            local_currency => 'ccc',
        );

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
            client    => $client,
        );

        BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
        $client->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'buyer_underpaid',
        );

        $client->p2p_resolve_order_dispute(
            id     => $order->{id},
            action => 'refund',
            staff  => 'me',
            fraud  => 0,
        );

        $stats_adv->{buy_completion_rate}   = '0.0';
        $stats_adv->{total_completion_rate} = '50.0';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };

    subtest 'buy ad complete' => sub {
        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
            type           => 'buy',
            client         => $advertiser,
            local_currency => 'ddd',
        );

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
            client    => $client,
        );

        BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
        $client->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'buyer_underpaid',
        );

        $client->p2p_resolve_order_dispute(
            id     => $order->{id},
            action => 'complete',
            staff  => 'me',
            fraud  => 0,
        );

        $stats_adv->{buy_completion_rate}   = '50.0';
        $stats_adv->{total_completion_rate} = '66.7';
        $stats_adv->{buy_orders_count}      = 1;
        $stats_adv->{total_orders_count}    = 2;
        $stats_cli->{sell_orders_count}     = 1;
        $stats_cli->{total_orders_count}    = 2;
        $stats_cli->{sell_completion_rate}  = '100.0';
        $stats_cli->{total_completion_rate} = '100.0';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };

    subtest 'sell ad refund' => sub {
        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
            type           => 'sell',
            client         => $advertiser,
            local_currency => 'ddd',
        );

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
            client    => $client,
        );

        BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
        $client->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'buyer_underpaid',
        );

        $client->p2p_resolve_order_dispute(
            id     => $order->{id},
            action => 'refund',
            staff  => 'me',
            fraud  => 0,
        );

        $stats_cli->{buy_completion_rate}   = '50.0';
        $stats_cli->{total_completion_rate} = '66.7';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };
};

subtest 'different advertiser' => sub {
    my $advertiser2 = BOM::Test::Helper::P2P::create_advertiser;
    my $res         = $advertiser->p2p_advertiser_info(id => $advertiser2->p2p_advertiser_info->{id});
    cmp_deeply($res, superhashof(\%default_stats), 'stats are for new advertiser');
};

BOM::Test::Helper::P2P::reset_escrow();

$emit_mock->unmock_all;
$client_mock->unmock_all;

done_testing();

sub check_stats {
    my ($client, $expected, $desc) = @_;
    cmp_deeply($client->p2p_advertiser_info, superhashof($expected), $desc);
}
