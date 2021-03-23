use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Runtime;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

BOM::Config::Runtime->instance->app_config->payments->p2p->cancellation_grace_period(0);

my $adv1 = BOM::Test::Helper::P2P::create_advertiser(balance => 100);
my $adv2 = BOM::Test::Helper::P2P::create_advertiser(balance => 100);

my (undef, $buy_ad1) = BOM::Test::Helper::P2P::create_advert(
    client => $adv1,
    type   => 'buy',
    rate   => 100
);
my (undef, $buy_ad2) = BOM::Test::Helper::P2P::create_advert(
    client => $adv2,
    type   => 'buy',
    rate   => 99
);
my (undef, $sell_ad1) = BOM::Test::Helper::P2P::create_advert(
    client => $adv1,
    type   => 'sell',
    rate   => 100
);
my (undef, $sell_ad2) = BOM::Test::Helper::P2P::create_advert(
    client => $adv2,
    type   => 'sell',
    rate   => 101
);

is $adv1->p2p_advert_list(id => $buy_ad1->{id})->[0]{advertiser_details}{total_completion_rate}, undef, 'no completion rate yet or advertiser 1';
is $adv1->p2p_advert_list(id => $buy_ad2->{id})->[0]{advertiser_details}{total_completion_rate}, undef, 'no completion rate yet or advertiser 2';

my $order = $adv1->p2p_order_create(
    advert_id => $sell_ad2->{id},
    amount    => 10
);
$adv1->p2p_order_cancel(id => $order->{id});

$order = $adv2->p2p_order_create(
    advert_id    => $buy_ad1->{id},
    amount       => 11,
    contact_info => 'x',
    payment_info => 'x'
);
$adv1->p2p_order_cancel(id => $order->{id});

$order = $adv2->p2p_order_create(
    advert_id => $sell_ad1->{id},
    amount    => 10
);
$adv2->p2p_order_confirm(id => $order->{id});
$adv1->p2p_order_confirm(id => $order->{id});

$order = $adv1->p2p_order_create(
    advert_id    => $buy_ad2->{id},
    amount       => 11,
    contact_info => 'x',
    payment_info => 'x'
);
$adv2->p2p_order_confirm(id => $order->{id});
$adv1->p2p_order_confirm(id => $order->{id});

my @ids = map { $_->{id} } $adv1->p2p_advert_list(
    type    => 'buy',
    sort_by => 'rate'
)->@*;
cmp_deeply(\@ids, [$buy_ad1->{id}, $buy_ad2->{id}], 'highest rate first for buy ads');

@ids = map { $_->{id} } $adv1->p2p_advert_list(
    type    => 'buy',
    sort_by => 'completion'
)->@*;
cmp_deeply(\@ids, [$buy_ad2->{id}, $buy_ad1->{id}], 'sort buy ads by completion');

@ids = map { $_->{id} } $adv1->p2p_advert_list(
    type    => 'sell',
    sort_by => 'rate'
)->@*;
cmp_deeply(\@ids, [$sell_ad1->{id}, $sell_ad2->{id}], 'lowest rate first for buy ads');

@ids = map { $_->{id} } $adv1->p2p_advert_list(
    type    => 'sell',
    sort_by => 'completion'
)->@*;
cmp_deeply(\@ids, [$sell_ad2->{id}, $sell_ad1->{id}], 'sort sell ads by completion');

is $adv1->p2p_advert_list(id => $buy_ad1->{id})->[0]{advertiser_details}{total_completion_rate}, '50.0',  'completion rate for advertiser 1';
is $adv1->p2p_advert_list(id => $buy_ad2->{id})->[0]{advertiser_details}{total_completion_rate}, '100.0', 'completion rate for advertiser 2';

BOM::Test::Helper::P2P::reset_escrow();

done_testing;
