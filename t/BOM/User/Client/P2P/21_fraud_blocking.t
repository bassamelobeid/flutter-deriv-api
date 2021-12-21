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
use Test::Fatal;
use Test::Exception;
use Test::MockModule;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

my $dt = Date::Utility->new('2000-01-01T00:00:00Z');

sub tt_days {
    $dt = $dt->plus_time_interval(shift . 'd');
    set_fixed_time($dt->iso8601);
}
tt_days(0);

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p->fraud_blocking;

$config->buy_count(1);
$config->buy_period(1);
$config->sell_count(1);
$config->sell_period(1);

my $emit_args;
my $emit_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
$emit_mock->mock(
    'emit',
    sub {
        $emit_args->{$_[0]} = $_[1];
        return $emit_mock->original('emit')->(@_);
    });

my @tests = ({
        name             => 'client is buyer',
        ad_type          => 'sell',
        resolution       => 'refund',
        client_block     => 1,
        advertiser_block => 0,
    },
    {
        name             => 'client is seller',
        ad_type          => 'buy',
        resolution       => 'complete',
        client_block     => 1,
        advertiser_block => 0,
    },
    {
        name             => 'advertiser is buyer',
        ad_type          => 'buy',
        resolution       => 'refund',
        client_block     => 0,
        advertiser_block => 1,
    },
    {
        name             => 'advertiser is seller',
        ad_type          => 'sell',
        resolution       => 'complete',
        client_block     => 0,
        advertiser_block => 1,
    },
);

testit($_->%*) for @tests;

$config->buy_count(2);

my ($advertiser, $client) = testit(
    name             => 'within limit',
    ad_type          => 'sell',
    resolution       => 'refund',
    client_block     => 0,
    advertiser_block => 0,
);

tt_days(2);

testit(
    name             => 'within limit 2 days later',
    ad_type          => 'sell',
    resolution       => 'refund',
    client           => $client,
    advertiser       => $advertiser,
    client_block     => 0,
    advertiser_block => 0,
);

testit(
    name             => 'exceed limit later',
    ad_type          => 'sell',
    resolution       => 'refund',
    client           => $client,
    advertiser       => $advertiser,
    client_block     => 1,
    advertiser_block => 0,
);

sub testit {
    my %test = @_;

    my ($advertiser, $client, $advert, $order);
    subtest $test{name} => sub {
        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
            type   => $test{ad_type},
            client => $test{advertiser});
        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 10,
            client    => $test{client});

        BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});

        $advertiser->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'buyer_underpaid',
        );

        $emit_args = {};
        $client->p2p_resolve_order_dispute(
            id     => $order->{id},
            action => $test{resolution},
            staff  => 'me',
            fraud  => 1,
        );
        my $expected_event = join('_', 'dispute', 'fraud', $test{resolution});

        delete $_->{_p2p_advertiser_cached} for ($client, $advertiser);    # reset cache
        is $client->p2p_is_advertiser_blocked     ? 1 : 0, $test{client_block},     'client block state';
        is $advertiser->p2p_is_advertiser_blocked ? 1 : 0, $test{advertiser_block}, 'advertiser block state';
        is $emit_args->{p2p_order_updated}->{order_event}, $expected_event, 'order event is correct';
        # to prevent duplicate_ad error
        $advertiser->p2p_advert_update(
            id        => $advert->{id},
            is_active => 0
        ) unless $test{advertiser_block};
    };
    return ($advertiser, $client);
}

# reset defaults
$config->buy_count(3);
$config->buy_period(0);
$config->sell_count(3);
$config->sell_period(0);

$emit_mock->unmock_all;

done_testing();
