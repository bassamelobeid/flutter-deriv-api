use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use Test::Fatal;
use Test::Exception;
use Guard;

populate_exchange_rates({EUR => 2});
BOM::Test::Helper::P2P::bypass_sendbird();
my $original_admax = BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert;
BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert(1000);
BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_order(100);

my $original_escrow = BOM::Config::Runtime->instance->app_config->payments->p2p->escrow;
my $escrow_client   = BOM::Test::Helper::Client::create_client();
$escrow_client->account('EUR');
BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([$escrow_client->loginid]);

scope_guard {
    BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert($original_admax);
    BOM::Config::Runtime->instance->app_config->payments->p2p->escrow($original_escrow);
};

my ($client, $advertiser, $ad);

subtest 'Default band' => sub {
    $advertiser = BOM::Test::Helper::P2P::create_advertiser(
        balance  => 1000,
        currency => 'EUR'
    );
    $ad = $advertiser->p2p_advert_create(
        amount           => 500,
        type             => 'sell',
        rate             => 1,
        min_order_amount => 1,
        max_order_amount => 50,
        local_currency   => 'myr',
        payment_method   => 'bank_transfer',
        payment_info     => 'test',
        contact_info     => 'test'
    );
    order($ad->{id}, 30);
    # current limit is USD 100 = EUR 50
    my $err = exception {
        order($ad->{id}, 30);
    };

    cmp_deeply(
        $err,
        {
            error_code     => 'OrderMaximumTempExceeded',
            message_params => ['20.00', 'EUR']
        },
        'cannot create order that exceeds band limit'
    );
};

subtest 'Medium band for country' => sub {
    $advertiser->db->dbic->dbh->do("INSERT INTO p2p.p2p_country_trade_band VALUES ('id','medium','USD',200,200)");
    $advertiser->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET trade_band = 'medium' WHERE id = " . $advertiser->p2p_advertiser_info->{id});

    # current limit is USD 200 = EUR 100, current orders are EUR 30
    lives_ok { order($ad->{id}, 30) } 'order can be created now ';

    # current orders are EUR 60
    my $err = exception {
        order($ad->{id}, 50);
    };

    cmp_deeply(
        $err,
        {
            error_code     => 'OrderMaximumTempExceeded',
            message_params => ['40.00', 'EUR']
        },
        'cannot create order that exceeds band limit'
    );
};

subtest 'High band for country & currency' => sub {
    $advertiser->db->dbic->dbh->do("INSERT into p2p.p2p_country_trade_band VALUES ('id','high','EUR',110,110)");
    $advertiser->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET trade_band = 'high' WHERE id = " . $advertiser->p2p_advertiser_info->{id});

    # current limit EUR 110, current orders are EUR 60
    lives_ok { order($ad->{id}, 50) } 'order can be created now ';

    # current orders are EUR 110
    my $err = exception {
        order($ad->{id}, 10);
    };

    # Advert should be filtered out in db when limit currency is same as ad
    cmp_deeply($err, {error_code => 'AdvertNotFound'}, 'error is AdvertNotFound when the limit currency equals order currency');
};

subtest 'Check client band limits' => sub {
    # Test client is buyer and after buying from ad_1 he will not be able to create another order for a different ad like ad_2
    # Although advertiser 2 band limits are ok and there is no order for his add,
    # test client will not be able to create order for ad2 because he will be exceeding himself daily buy limit

    my $test_client = BOM::Test::Helper::P2P::create_advertiser(
        balance  => 1000,
        currency => 'EUR'
    );
    my $ad_cl = $test_client->p2p_advert_create(
        amount           => 500,
        type             => 'sell',
        rate             => 1,
        min_order_amount => 1,
        max_order_amount => 50,
        local_currency   => 'myr',
        payment_method   => 'bank_transfer',
        payment_info     => 'test',
        contact_info     => 'test'
    );

    my $advertiser_1 = BOM::Test::Helper::P2P::create_advertiser(
        balance  => 1000,
        currency => 'EUR'
    );
    my $ad_1 = $advertiser_1->p2p_advert_create(
        amount           => 500,
        type             => 'sell',
        rate             => 1,
        min_order_amount => 1,
        max_order_amount => 50,
        local_currency   => 'myr',
        payment_method   => 'bank_transfer',
        payment_info     => 'test',
        contact_info     => 'test'
    );

    # test client can create order for ad_1
    $test_client->p2p_order_create(
        advert_id => $ad_1->{id},
        amount    => 30
    );

    my $advertiser_2 = BOM::Test::Helper::P2P::create_advertiser(
        balance  => 1000,
        currency => 'EUR'
    );
    my $ad_2 = $advertiser_2->p2p_advert_create(
        amount           => 500,
        type             => 'sell',
        rate             => 1,
        min_order_amount => 1,
        max_order_amount => 50,
        local_currency   => 'myr',
        payment_method   => 'bank_transfer',
        payment_info     => 'test',
        contact_info     => 'test'
    );

    # reset cache otherwise limits will be stale
    delete $test_client->{_p2p_advertiser};

    # test client cannot create order for a different ad (ad2) because of exceding daily buy limit
    my $err = exception {
        $test_client->p2p_order_create(
            advert_id => $ad_2->{id},
            amount    => 25
        );
    };

    cmp_deeply(
        $err,
        {
            error_code     => 'OrderMaximumTempExceeded',
            message_params => ['20.00', 'EUR']
        },
        'client cannot create order if exceeds daily buy limit'
    );
};

subtest 'ad list' => sub {
    BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $ad) = BOM::Test::Helper::P2P::create_advert(
        amount           => 100,
        min_order_amount => 10,
        max_order_amount => 100,
        type             => 'sell'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        amount    => 100,
        advert_id => $ad->{id});
    my ($advertiser2, $ad2) = BOM::Test::Helper::P2P::create_advert(type => 'sell');

    is scalar(
        $client->p2p_advert_list(
            id                => $ad2->{id},
            use_client_limits => 1
        )->@*
        ),
        0, 'sell ad is hidden with use_client_limits=1';
    is scalar($client->p2p_advert_list(id => $ad2->{id})->@*), 1, 'sell ad is shown without use_client_limits';

    ($advertiser, $ad) = BOM::Test::Helper::P2P::create_advert(
        amount           => 100,
        min_order_amount => 10,
        max_order_amount => 100,
        type             => 'buy'
    );
    ($client, $order) = BOM::Test::Helper::P2P::create_order(
        balance   => 100,
        amount    => 100,
        advert_id => $ad->{id});
    ($advertiser2, $ad2) = BOM::Test::Helper::P2P::create_advert(type => 'buy');

    is scalar(
        $client->p2p_advert_list(
            id                => $ad2->{id},
            use_client_limits => 1
        )->@*
        ),
        0, 'buy ad is hidden with use_client_limits=1';
    is scalar($client->p2p_advert_list(id => $ad2->{id})->@*), 1, 'buy ad is shown without use_client_limits=1';

    BOM::Test::Helper::P2P::reset_escrow();
};

sub order {
    my ($advert_id, $amount) = @_;
    $client = BOM::Test::Helper::P2P::create_advertiser(currency => 'EUR');
    $client->p2p_order_create(
        advert_id => $advert_id,
        amount    => $amount
    );
}

done_testing();
