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

BOM::Test::Helper::P2P::create_escrow();
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

subtest 'amount filter' => sub {
    plan skip_all => "We don't filter advert list for now, but might do later";

    is $client->p2p_advert_list()->@*, 1, 'No filter gets advert';
    is $client->p2p_advert_list(amount => 101)->@*, 0, 'Filter out >amount';
    is $client->p2p_advert_list(amount => 99)->@*,  1, 'Not filter out <amount';

    $advertiser1->p2p_advert_update(
        id         => $advert1->{id},
        max_amount => 90
    );
    is $client->p2p_advert_list(amount => 91)->@*, 0, 'Filter out >max';
    is $client->p2p_advert_list(amount => 89)->@*, 1, 'Not filter out <max';

    BOM::Test::Helper::P2P::create_order(
        advert_id => $advert1->{advert_id},
        amount    => 20
    );    # advert remaining is now 80
    is $client->p2p_advert_list(amount => 81)->@*, 0, 'Filter out >remaining';
    is $client->p2p_advert_list(amount => 79)->@*, 1, 'Not filter out <remaining';

    $app_config->payments->p2p->limits->maximum_order(70);
    is $client->p2p_advert_list(amount => 71)->@*, 0, 'Filter out >config max';
    is $client->p2p_advert_list(amount => 69)->@*, 1, 'Not filter out <config max';
};

BOM::Test::Helper::P2P::reset_escrow();

# restore app config
$app_config->payments->p2p->limits->maximum_order($max_order);

done_testing();
