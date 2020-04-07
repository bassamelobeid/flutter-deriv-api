use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;

use BOM::User::Client;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Runtime;

my $app_config = BOM::Config::Runtime->instance->app_config;
my $max_order  = $app_config->payments->p2p->limits->maximum_order;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

subtest 'Seller lists ads and those with a min order amount greater than its balance are excluded' => sub {
    my $seller_balance = 10;
    my $escrow         = BOM::Test::Helper::P2P::create_escrow();
    my $seller         = BOM::Test::Helper::P2P::create_client($seller_balance);

    cmp_ok $seller->account->balance, '==', $seller_balance, "Seller balance is $seller_balance";

    # this ad should be available for our buyer
    my (undef, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        type             => 'buy',
        amount           => $seller_balance * 0.5,
        max_order_amount => $seller_balance * 0.5,
        min_order_amount => $seller_balance * 0.1
    );

    # this ad should NOT be available for our buyer
    BOM::Test::Helper::P2P::create_advert(
        type             => 'buy',
        amount           => $seller_balance * 1.5,
        max_order_amount => $seller_balance * 1.5,
        min_order_amount => $seller_balance * 1.1
    );

    is scalar($seller->p2p_advert_list->@*), 1, 'List correct amount of ads (1)';
    cmp_ok $seller->p2p_advert_list->[0]->{id}, '==', $advert_info->{id}, 'List ad is the expected one';
};

my ($advertiser1, $advert1) = BOM::Test::Helper::P2P::create_advert(amount => 100);
my ($advertiser2, $advert2) = BOM::Test::Helper::P2P::create_advert(amount => 100);
my $client = BOM::Test::Helper::P2P::create_client();
subtest 'advertiser adverts' => sub {
    cmp_deeply(
        exception {
            $client->p2p_advertiser_adverts()
        },
        {error_code => 'AdvertiserNotRegistered'},
        "non advertiser gets error"
    );

    $advertiser2->p2p_advertiser_update(is_listed => 0);

    is $advertiser1->p2p_advertiser_adverts()->[0]{id}, $advert1->{id}, 'advertiser 1 (active) gets advert';
    is $advertiser1->p2p_advertiser_adverts()->@*, 1, 'advertiser 1 got one';
    is $advertiser2->p2p_advertiser_adverts()->[0]{id}, $advert2->{id}, 'advertiser 2 (inactive) gets advert';
    is $advertiser2->p2p_advertiser_adverts()->@*, 1, 'advertiser 2 got one';
};

BOM::Test::Helper::P2P::reset_escrow();

# restore app config
$app_config->payments->p2p->limits->maximum_order($max_order);

done_testing();
