use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;
use Test::MockTime qw(set_fixed_time);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use Test::Fatal;
use Test::Exception;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$config->cancellation_grace_period(10);

my $redis = BOM::Config::Redis->redis_p2p();

my $dt = Date::Utility->new('2000-01-01T00:00:00Z');

sub tt_hours {
    $dt = $dt->plus_time_interval(shift . 'h');
    set_fixed_time($dt->iso8601);
}
tt_hours(0);

my %ad_params = (
    type             => 'sell',
    amount           => 10,
    min_order_amount => 1,
    max_order_amount => 10,
    rate             => 1,
    payment_method   => 'x',
    payment_info     => 'x',
    contact_info     => 'x'
);

subtest general => sub {
    $config->cancellation_barring->count(2);
    $config->cancellation_barring->period(2);
    $config->cancellation_barring->bar_time(24);

    my ($advertiser, $ad1) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my ($client, $ord1, $ord2, $ord3);

    ($client, $ord1) = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad1->{id},
        amount    => 1
    );

    tt_hours(1);
    $client->p2p_order_cancel(id => $ord1->{id});
    ($client, $ord2) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $ord1->{id},
        amount    => 1,
    );

    tt_hours(1);
    my $ad2 = (BOM::Test::Helper::P2P::create_advert(type => 'sell'))[1];
    ($client, $ord3) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $ad2->{id},
        amount    => 1
    );
    $client->p2p_order_cancel(id => $ord2->{id});

    my $block_until = Date::Utility->new('2000-01-02T02:00:00Z');

    my $expected_error = {
        error_code     => 'TemporaryBar',
        message_params => [$block_until->datetime]};

    cmp_deeply(exception { $client->p2p_order_create(advert_id => $ad1->{id}, amount => 1) }, $expected_error, 'barred for create order',);

    cmp_deeply(exception { $client->p2p_advert_create(%ad_params) }, $expected_error, 'barred for create ad',);

    is $client->p2p_advertiser_info->{blocked_until}, $block_until->epoch, 'p2p_advertiser_info returns blocked_until';
    is $advertiser->p2p_advertiser_info(id => $client->p2p_advertiser_info->{id})->{blocked_until}, undef, 'other advertiser cannot see it';

    is $redis->zscore('P2P::ADVERTISER::BLOCK_ENDS_AT', $client->loginid), $block_until->epoch, 'block end time saved in redis';

    tt_hours(1);
    lives_ok { $client->p2p_order_cancel(id => $ord3->{id}) } 'can cancel ad when barred';

    cmp_deeply(exception { $client->p2p_order_create(advert_id => $ad1->{id}, amount => 1) }, $expected_error, 'bar time does not increase',);

    tt_hours(22);
    cmp_deeply(exception { $client->p2p_order_create(advert_id => $ad1->{id}, amount => 1) }, $expected_error, 'still blocked after 12 hours',);

    tt_hours(1);
    lives_ok { $client->p2p_order_create(advert_id => $ad1->{id}, amount => 1) } 'can create order at hour 25';
    lives_ok { $client->p2p_advert_create(%ad_params) } 'can create ad at hour 25';

    is $client->p2p_advertiser_info->{blocked_until}, undef, 'p2p_advertiser_info blocked_until is undef now';
};

subtest 'timeouts and disputes' => sub {
    $config->cancellation_barring->count(1);
    $config->cancellation_barring->period(100);    # crazy but possible

    my $ad1 = (BOM::Test::Helper::P2P::create_advert(type => 'sell'))[1];
    my ($client, $ord1) = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad1->{id},
        amount    => 10
    );

    $client->p2p_order_confirm(id => $ord1->{id});

    tt_hours(2);
    BOM::Test::Helper::P2P::expire_order($client, $ord1->{id});
    $client->p2p_expire_order(id => $ord1->{id});

    my $ord2;
    lives_ok { ($client, $ord2) = BOM::Test::Helper::P2P::create_order(client => $client, advert_id => $ad1->{id}, amount => 10) }
    'timed-out order does not count as cancel';
    $client->p2p_order_cancel(id => $ord2->{id});    # grace period

    BOM::Test::Helper::P2P::ready_to_refund($client, $ord1->{id});
    $client->p2p_expire_order(id => $ord1->{id});

    my $ord3;
    lives_ok { ($client, $ord3) = BOM::Test::Helper::P2P::create_order(client => $client, advert_id => $ad1->{id}, amount => 10) }
    'timeded out refunded order does not count as cancel';

    BOM::Test::Helper::P2P::set_order_disputable($client, $ord3->{id});
    $client->p2p_create_order_dispute(
        id             => $ord3->{id},
        dispute_reason => 'seller_not_released',
    );

    $client->p2p_resolve_order_dispute(
        id     => $ord3->{id},
        action => 'refund',
        staff  => 'me',
        fraud  => 0,
    );

    my $ord4;
    lives_ok { ($client, $ord4) = BOM::Test::Helper::P2P::create_order(client => $client, advert_id => $ad1->{id}, amount => 10) }
    'dispute refunded order does not count as cancel';
    tt_hours(2);
    BOM::Test::Helper::P2P::expire_order($client, $ord4->{id});
    $client->p2p_expire_order(id => $ord4->{id});
    cmp_deeply(
        exception { $client->p2p_order_create(advert_id => $ad1->{id}, amount => 10) },
        {
            error_code     => 'TemporaryBar',
            message_params => [Date::Utility->new->plus_time_interval('24h')->datetime]
        },
        'order expiry while pending does count towards bar',
    );
};

subtest 'buy ads' => sub {

    my ($advertiser, $ad)    = BOM::Test::Helper::P2P::create_advert(type => 'buy');
    my ($client,     $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad->{id},
        amount    => 10
    );
    tt_hours(2);
    BOM::Test::Helper::P2P::expire_order($client, $order->{id});
    $client->p2p_expire_order(id => $order->{id});
    is $advertiser->_p2p_advertiser_stats($advertiser->loginid, 100)->{cancel_count}, 1, 'advertiser cancel count was increased';
    is $client->_p2p_advertiser_stats($client->loginid, 100)->{cancel_count},         0, 'client cancel count was not increased';
};

done_testing();
