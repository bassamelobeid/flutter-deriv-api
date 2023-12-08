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
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);
use BOM::User::Client;
use Test::Fatal;
use Test::Exception;
use Date::Utility;
use Test::MockModule;
use JSON::MaybeUTF8 qw(:v1);

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$config->limits->count_per_day_per_client(10);
$config->cancellation_grace_period(10);
$config->cancellation_barring->count(10);
$config->transaction_verification_countries([]);
$config->transaction_verification_countries_all(0);

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();
populate_exchange_rates({IDR => 1});

my ($advertiser, $client, $advert, $order, $stats_cli, $stats_adv);

my %default_stats = (
    'buy_orders_count'      => 0,
    'buy_orders_amount'     => '0.00',
    'sell_orders_count'     => 0,
    'sell_orders_amount'    => '0.00',
    'total_orders_count'    => 0,
    'total_turnover'        => '0.00',
    'buy_time_avg'          => undef,
    'release_time_avg'      => undef,
    'cancel_time_avg'       => undef,
    'total_completion_rate' => undef,
    'buy_completion_rate'   => undef,
    'sell_completion_rate'  => undef,
    'basic_verification'    => 0,
    'full_verification'     => 0,
    'partner_count'         => 0,
    'advert_rates'          => undef,
);

my $dt = Date::Utility->new('2000-01-01T00:00:00Z');

sub tt_secs {
    my $secs = shift;
    $dt = $dt->plus_time_interval($secs . 's');
    set_fixed_time($dt->iso8601);
}

my $emit_args;
my $emit_mock   = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $client_mock = Test::MockModule->new('Deriv::P2P');
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

reset_stats();

subtest 'verification' => sub {

    $advertiser = BOM::Test::Helper::P2P::create_advertiser(balance => 100);
    check_stats($advertiser->{client}, $stats_adv, 'stats for new advertiser');

    $advertiser->{client}->status->set('age_verification', 'system', 'testing');
    $stats_adv->{basic_verification} = 1;
    check_stats($advertiser->{client}, $stats_adv, 'age verified sets basic verification');

    $advertiser->{client}->set_authentication('ID_ONLINE', {status => 'pass'});
    $stats_adv->{full_verification} = 1;
    check_stats($advertiser->{client}, $stats_adv, 'POA sets basic verification');
};

subtest 'sell ads' => sub {
    tt_secs(0);

    ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        client         => $advertiser,
        type           => 'sell',
        local_currency => 'IDR',
    );

    $stats_adv->{advert_rates} = '0.00';
    check_stats($advertiser->{client}, $stats_adv, 'advertiser stats after order created');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 1,
        balance   => 100
    );

    check_stats($advertiser, $stats_adv, 'advertiser stats after order created');
    check_stats($client,     $stats_cli, 'client stats after order created');

    tt_secs(500);
    $client->p2p_order_confirm(id => $order->{id});
    check_stats($advertiser, $stats_adv, 'advertiser stats after buyer confim');
    check_stats($client,     $stats_cli, 'client stats after buyer confirm');

    tt_secs(500);
    $advertiser->p2p_order_confirm(id => $order->{id});
    $stats_adv->{total_orders_count}   = ++$stats_cli->{total_orders_count};
    $stats_adv->{sell_orders_count}    = ++$stats_cli->{buy_orders_count};
    $stats_adv->{release_time_avg}     = 500;
    $stats_adv->{sell_completion_rate} = $stats_adv->{total_completion_rate} = '100.0';
    $stats_cli->{buy_completion_rate}  = $stats_cli->{total_completion_rate} = '100.0';
    $stats_cli->{total_turnover}       = $stats_adv->{total_turnover}        = $stats_cli->{buy_orders_amount} = $stats_adv->{sell_orders_amount} =
        $order->{amount};
    $stats_adv->{partner_count} = ++$stats_cli->{partner_count};
    $stats_cli->{buy_time_avg}  = 500;
    check_stats($advertiser, $stats_adv, 'advertiser stats after seller confim');
    check_stats($client,     $stats_cli, 'client stats after seller confirm');

    is $client->p2p_advert_info(id => $advert->{id})->{advertiser_details}{completed_orders_count}, 1,
        'advertiser completed_orders_count increases after buy order completed';

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
    $client->db->dbic->dbh->do('UPDATE p2p.p2p_advertiser_totals_daily SET day = day - 60');

    is $client->p2p_advert_info(id => $advert->{id})->{advertiser_details}{completed_orders_count}, 0,
        'advert advertiser completed_orders_count resets in future';

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 2
    );
    tt_secs(5);
    $client->p2p_order_confirm(id => $order->{id});
    tt_secs(10);
    $advertiser->p2p_order_confirm(id => $order->{id});
    $stats_cli->{total_orders_count}  = ++$stats_adv->{total_orders_count};
    $stats_cli->{buy_orders_count}    = $stats_adv->{sell_orders_count} = 1;
    $stats_cli->{buy_time_avg}        = 5;
    $stats_adv->{release_time_avg}    = 10;
    $stats_cli->{cancel_time_avg}     = undef;
    $stats_cli->{buy_completion_rate} = $stats_cli->{total_completion_rate} = '100.0';
    $stats_cli->{total_turnover}      = $stats_adv->{total_turnover}        = '3.00';
    $stats_cli->{buy_orders_amount}   = $stats_adv->{sell_orders_amount}    = '2.00';
    $stats_adv->{advert_rates}        = undef;
    check_stats($advertiser, $stats_adv, 'advertiser stats in future');
    check_stats($client,     $stats_cli, 'client stats in future');
    is $client->p2p_advert_info(id => $advert->{id})->{advertiser_details}{completed_orders_count}, 1,
        'advert advertiser completed_orders_count increases after buy order completed';

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
        client         => $advertiser,
        type           => 'buy',
        local_currency => 'IDR',
    );

    $stats_adv->{advert_rates} = '0.00';
    check_stats($advertiser, $stats_adv, 'advertiser stats after order created');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $advert->{id},
        amount    => 3
    );

    check_stats($advertiser, $stats_adv, 'advertiser stats after order created');
    check_stats($client,     $stats_cli, 'client stats after order created');

    tt_secs(500);
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
    $stats_cli->{total_turnover}       = $stats_adv->{total_turnover}        = '6.00';
    $stats_cli->{sell_orders_amount}   = $stats_adv->{buy_orders_amount}     = '3.00';
    $stats_adv->{buy_time_avg}         = 500;
    check_stats($advertiser, $stats_adv, 'advertiser stats after seller confirm');
    check_stats($client,     $stats_cli, 'client stats after seller confirm');

    is $client->p2p_advert_info(id => $advert->{id})->{advertiser_details}{completed_orders_count}, 2,
        'advert advertiser completed_orders_count after sell order completed';

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

subtest 'expire within/beyond grace period' => sub {

    my (undef, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => 1,
        expiry    => 5,               # grace period is 10min
    );

    tt_secs(6);
    BOM::Test::Helper::P2P::expire_order($advertiser, $order->{id});
    $client->p2p_expire_order(id => $order->{id});

    delete $client->{_p2p_advertiser_cached};
    is $client->p2p_advertiser_info->{total_completion_rate}, undef, 'within grace period: undef buy completion';
    is $client->p2p_advertiser_info->{buy_completion_rate},   undef, 'within grace period: undef total completion';

    (undef, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');

    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => 1,
        expiry    => 10 * 60,
    );

    tt_secs((10 * 60) + 1);
    BOM::Test::Helper::P2P::expire_order($advertiser, $order->{id});
    $client->p2p_expire_order(id => $order->{id});

    delete $client->{_p2p_advertiser_cached};
    cmp_ok $client->p2p_advertiser_info->{total_completion_rate}, '==', 0, 'beyond grace period: zero buy completion';
    cmp_ok $client->p2p_advertiser_info->{buy_completion_rate},   '==', 0, 'beyond grace period: zero total completion';
};

subtest 'dispute resolution - fraud' => sub {

    subtest 'advertiser seller fraud' => sub {
        reset_stats();

        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
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
        $stats_cli->{total_orders_count}    = $stats_cli->{buy_orders_count}     = 1;
        $stats_cli->{total_turnover}        = $stats_cli->{buy_orders_amount}    = $order->{amount};
        $stats_adv->{advert_rates}          = '0.00';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };

    subtest 'advertiser buyer fraud' => sub {
        reset_stats();

        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'buy');

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
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

        $stats_adv->{total_completion_rate} = $stats_adv->{buy_completion_rate} = '0.0';
        $stats_adv->{advert_rates}          = '0.00';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };

    subtest 'client seller fraud' => sub {
        reset_stats();

        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'buy');

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
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

        $stats_adv->{total_completion_rate} = $stats_adv->{buy_completion_rate}  = '100.0';
        $stats_cli->{total_completion_rate} = $stats_cli->{sell_completion_rate} = '0.0';
        $stats_adv->{total_orders_count}    = $stats_adv->{buy_orders_count}     = 1;
        $stats_adv->{total_turnover}        = $stats_adv->{buy_orders_amount}    = $order->{amount};
        $stats_adv->{advert_rates}          = '0.00';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };

    subtest 'client buyer fraud' => sub {
        reset_stats();

        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
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

        $stats_cli->{total_completion_rate} = $stats_cli->{buy_completion_rate} = '0.0';
        $stats_adv->{advert_rates}          = '0.00';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };
};

subtest 'dispute resolution - no fraud' => sub {

    subtest 'sell ad complete' => sub {
        reset_stats();

        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
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
        $stats_cli->{total_turnover}        = $stats_adv->{total_turnover} = $stats_cli->{buy_orders_amount} = $stats_adv->{sell_orders_amount} =
            $order->{amount};
        $stats_adv->{partner_count} = ++$stats_cli->{partner_count};
        $stats_adv->{advert_rates}  = '0.00';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };

    subtest 'buy ad refund' => sub {
        reset_stats();

        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'buy');

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
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

        $stats_adv->{buy_completion_rate} = $stats_adv->{total_completion_rate} = '0.0';
        $stats_adv->{advert_rates}        = '0.00';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };

    subtest 'buy ad complete' => sub {
        reset_stats();

        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'buy');

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
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

        $stats_adv->{total_completion_rate} = $stats_adv->{buy_completion_rate}  = '100.0';
        $stats_cli->{total_completion_rate} = $stats_cli->{sell_completion_rate} = '100.0';
        $stats_adv->{buy_orders_count}      = $stats_cli->{total_orders_count}   = 1;
        $stats_cli->{sell_orders_count}     = $stats_adv->{total_orders_count}   = 1;
        $stats_cli->{total_turnover}        = $stats_adv->{total_turnover} = $stats_cli->{sell_orders_amount} = $stats_adv->{buy_orders_amount} =
            $order->{amount};
        $stats_adv->{partner_count} = ++$stats_cli->{partner_count};
        $stats_adv->{advert_rates}  = '0.00';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };

    subtest 'sell ad refund' => sub {
        reset_stats();

        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 1,
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

        $stats_cli->{total_completion_rate} = $stats_cli->{buy_completion_rate} = '0.0';
        $stats_adv->{advert_rates}          = '0.00';
        check_stats($advertiser, $stats_adv, 'advertiser stats');
        check_stats($client,     $stats_cli, 'client stats');
    };
};

subtest 'different advertiser' => sub {
    my $advertiser2 = BOM::Test::Helper::P2P::create_advertiser;
    my $res         = $advertiser->p2p_advertiser_info(id => $advertiser2->p2p_advertiser_info->{id});
    cmp_deeply($res, superhashof(\%default_stats), 'stats are for new advertiser');
};

subtest 'trade partners' => sub {
    my ($advertiser, $ad)     = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my ($client1,    $order1) = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad->{id},
        amount    => 10
    );
    my ($client2, $order2) = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad->{id},
        amount    => 10
    );
    $client1->p2p_order_confirm(id => $order1->{id});
    $client2->p2p_order_confirm(id => $order2->{id});
    $advertiser->p2p_order_confirm(id => $order1->{id});
    $advertiser->p2p_order_confirm(id => $order2->{id});

    is $advertiser->p2p_advertiser_info->{partner_count}, 2, 'advertiser has 2 partners';
    is $client1->p2p_advertiser_info->{partner_count},    1, 'client A has 1 partner';
    is $client2->p2p_advertiser_info->{partner_count},    1, 'client B has 1 partner';
};

subtest 'advert rates' => sub {
    my $client = BOM::Test::Helper::P2P::create_advertiser;

    $config->country_advert_config(
        encode_json_utf8({
                $client->residence => {
                    float_ads => 'enabled',
                    fixed_ads => 'enabled'
                }}));

    BOM::Test::Helper::P2P::create_advert(
        client    => $client,
        type      => 'buy',
        rate      => 0.95,
        rate_type => 'fixed',
    );

    is $client->p2p_advertiser_info->{advert_rates}, '5.00', 'fixed buy rate';

    ($client) = BOM::Test::Helper::P2P::create_advert(
        type      => 'buy',
        rate      => 1.1,
        rate_type => 'fixed',
    );

    is $client->p2p_advertiser_info->{advert_rates}, '-10.00', 'fixed buy rate better than market';

    ($client) = BOM::Test::Helper::P2P::create_advert(
        type      => 'sell',
        rate      => 1.08,
        rate_type => 'fixed',
    );

    is $client->p2p_advertiser_info->{advert_rates}, '8.00', 'fixed sell rate';

    ($client) = BOM::Test::Helper::P2P::create_advert(
        type      => 'sell',
        rate      => 0.8,
        rate_type => 'fixed',
    );

    is $client->p2p_advertiser_info->{advert_rates}, '-20.00', 'fixed sell rate better than market';

    ($client) = BOM::Test::Helper::P2P::create_advert(
        type      => 'buy',
        rate      => -1.2,
        rate_type => 'float',
    );

    is $client->p2p_advertiser_info->{advert_rates}, '1.20', 'float buy rate';

    ($client) = BOM::Test::Helper::P2P::create_advert(
        type      => 'buy',
        rate      => 0.3,
        rate_type => 'float',
    );

    is $client->p2p_advertiser_info->{advert_rates}, '-0.30', 'float buy rate better than market';

    ($client) = BOM::Test::Helper::P2P::create_advert(
        type      => 'sell',
        rate      => 2.1,
        rate_type => 'float',
    );

    is $client->p2p_advertiser_info->{advert_rates}, '2.10', 'float sell rate';

    ($client) = BOM::Test::Helper::P2P::create_advert(
        type      => 'sell',
        rate      => -3.97,
        rate_type => 'float',
    );

    is $client->p2p_advertiser_info->{advert_rates}, '-3.97', 'float sell rate better than market';

    ($client) = BOM::Test::Helper::P2P::create_advert(
        type             => 'buy',
        rate             => 0.9,
        rate_type        => 'fixed',
        min_order_amount => 1,
        max_order_amount => 2,
    );

    BOM::Test::Helper::P2P::create_advert(
        client           => $client,
        type             => 'buy',
        rate             => 0.8,
        rate_type        => 'fixed',
        min_order_amount => 3,
        max_order_amount => 4,
    );

    is $client->p2p_advertiser_info->{advert_rates}, '15.00', 'averaging of multiple ads';
};

BOM::Test::Helper::P2P::reset_escrow();

$emit_mock->unmock_all;
$client_mock->unmock_all;

done_testing();

sub check_stats {
    my ($client, $expected, $desc) = @_;
    delete $client->{_p2p_advertiser_cached};
    cmp_deeply($client->p2p_advertiser_info, superhashof($expected), $desc);
}

sub reset_stats {
    $stats_cli = {%default_stats};
    $stats_adv = {%default_stats};
}
