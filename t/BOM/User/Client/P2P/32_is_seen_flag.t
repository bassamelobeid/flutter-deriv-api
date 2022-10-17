use strict;
use warnings;

use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2P;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
my $redis  = BOM::Config::Redis->redis_p2p_write;
$redis->del('P2P::ORDER::LAST_SEEN_STATUS');

subtest 'order created and completed normally' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order_create_response) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );
    is $order_create_response->{is_seen}, 1, 'buyer is_seen flag is 1';
    my $order_id = $order_create_response->{id};
    my $order    = $advertiser->_p2p_orders(id => $order_id)->[0];

    # before seller call p2p_order_info when status is pending
    is $advertiser->_order_details([$order])->[0]->{is_seen}, 0, 'seller is_seen flag is 0';

    # after seller call p2p_orer_info when status is pending
    is $advertiser->p2p_order_info(id => $order_id)->{is_seen}, 1, 'seller is_seen flag is 1';

    # buyer clicked I've paid
    $client->p2p_order_confirm(id => $order_id);
    $order = $client->_p2p_orders(id => $order_id)->[0];
    is $client->_order_details([$order])->[0]->{is_seen}, 1, 'buyer is_seen flag is 1';

    # before seller call p2p_order_info when status is buyer-confimed
    is $advertiser->_order_details([$order])->[0]->{is_seen}, 0, 'seller is_seen flag is 0';

    # after seller call p2p_orer_info when status is buyer-confimed
    is $advertiser->p2p_order_info(id => $order_id)->{is_seen}, 1, 'seller is_seen flag is 1';

    # seller confirm
    $advertiser->p2p_order_confirm(id => $order_id);

    # after seller confirm order
    is $advertiser->p2p_order_info(id => $order_id)->{is_seen}, undef, 'is_seen flag not returned to seller';
    is $client->p2p_order_info(id => $order_id)->{is_seen},     undef, 'is_seen flag not returned to buyer';

};

subtest 'order created, becomes timed-out and completed normally' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order_create_response) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );
    my $order_id = $order_create_response->{id};

    # buyer clicked I've paid
    $client->p2p_order_confirm(id => $order_id);

    #set order status to timed-out
    BOM::Test::Helper::P2P::set_order_disputable($client, $order_id);

    my $order = $client->_p2p_orders(id => $order_id)->[0];

    # before seller and buyer call p2p_order_info when status is timed-out
    is $client->_order_details([$order])->[0]->{is_seen},     0, 'buyer is_seen flag is 0';
    is $advertiser->_order_details([$order])->[0]->{is_seen}, 0, 'seller is_seen flag is 0';

    # after seller and buyer call p2p_order_info when status is timed-out
    is $client->p2p_order_info(id => $order_id)->{is_seen},     1, 'buyer is_seen flag is 1';
    is $advertiser->p2p_order_info(id => $order_id)->{is_seen}, 1, 'seller is_seen flag is 1';

    # seller confirm
    $advertiser->p2p_order_confirm(id => $order_id);

    # after seller confirm order
    is $advertiser->p2p_order_info(id => $order_id)->{is_seen}, undef, 'is_seen flag not returned to seller';
    is $client->p2p_order_info(id => $order_id)->{is_seen},     undef, 'is_seen flag not returned to buyer';

};
subtest 'order cancelled' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order_create_response) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );
    my $order_id = $order_create_response->{id};

    $client->p2p_order_cancel(id => $order_id);
    my $order = $client->_p2p_orders(id => $order_id)->[0];

    # before seller and buyer call p2p_order_info when status is cancelled
    is $client->_order_details([$order])->[0]->{is_seen},     undef, 'is_seen flag not returned to buyer';
    is $advertiser->_order_details([$order])->[0]->{is_seen}, undef, 'is_seen flag not returned to seller';

    # after seller and buyer call p2p_order_info when status is cancelled
    is $client->p2p_order_info(id => $order_id)->{is_seen},     undef, 'is_seen flag not returned to buyer';
    is $advertiser->p2p_order_info(id => $order_id)->{is_seen}, undef, 'is_seen flag not returned to seller';
};
subtest 'order expires without any action from buyer' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order_create_response) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );
    my $order_id = $order_create_response->{id};

    BOM::Test::Helper::P2P::expire_order($client, $order_id);
    BOM::Test::Helper::P2P::set_order_status($client, $order_id, "refunded");
    my $order = $client->_p2p_orders(id => $order_id)->[0];

    # before seller and buyer call p2p_order_info when status is refunded
    is $client->_order_details([$order])->[0]->{is_seen},     undef, 'is_seen flag not returned to buyer';
    is $advertiser->_order_details([$order])->[0]->{is_seen}, undef, 'is_seen flag not returned to seller';

    # after seller and buyer call p2p_order_info when status is refunded
    is $client->p2p_order_info(id => $order_id)->{is_seen},     undef, 'is_seen flag not returned to buyer';
    is $advertiser->p2p_order_info(id => $order_id)->{is_seen}, undef, 'is_seen flag not returned to seller';
};

subtest 'order becomes timed-out, buyer create dispute, dispute resolved by seller' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order_create_response) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );
    my $order_id = $order_create_response->{id};

    # buyer clicked I've paid
    $client->p2p_order_confirm(id => $order_id);

    #expire the order and set order status to timed-out
    BOM::Test::Helper::P2P::set_order_disputable($client, $order_id);

    my $response = $client->p2p_create_order_dispute(
        id             => $order_id,
        dispute_reason => 'seller_not_released',
        skip_livechat  => 1,
    );

    # after buyer created dispute
    is $response->{is_seen},                                1, 'buyer is_seen flag is 1';
    is $client->p2p_order_info(id => $order_id)->{is_seen}, 1, 'buyer is_seen flag is 1';

    # before seller call p2p_order_info when status is disputed
    my $order = $client->_p2p_orders(id => $order_id)->[0];
    is $advertiser->_order_details([$order])->[0]->{is_seen}, 0, 'seller is_seen flag is 0';

    # after seller call p2p_order_info when status is refunded
    is $advertiser->p2p_order_info(id => $order_id)->{is_seen}, 1, 'seller is_seen flag is 1';

    # seller confirm
    $advertiser->p2p_order_confirm(id => $order_id);

    # after seller confirm order
    is $advertiser->p2p_order_info(id => $order_id)->{is_seen}, undef, 'is_seen flag not returned to seller';
    is $client->p2p_order_info(id => $order_id)->{is_seen},     undef, 'is_seen flag not returned to buyer';

};
subtest 'order becomes timed-out, seller create dispute, dispute resolved in favor of seller' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type => 'sell',
    );

    my ($client, $order_create_response) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $advert->{min_order_amount},
    );
    my $order_id = $order_create_response->{id};

    # buyer clicked I've paid
    $client->p2p_order_confirm(id => $order_id);

    #expire the order and set order status to timed-out

    BOM::Test::Helper::P2P::set_order_disputable($client, $order_id);

    my $response = $client->p2p_create_order_dispute(
        id             => $order_id,
        dispute_reason => 'seller_not_released',
        skip_livechat  => 1,
    );

    # after buyer created dispute
    is $response->{is_seen},                                1, 'is_seen flag not returned to buyer';
    is $client->p2p_order_info(id => $order_id)->{is_seen}, 1, 'buyer is_seen flag is 1';

    # before seller call p2p_order_info when status is disputed
    my $order = $client->_p2p_orders(id => $order_id)->[0];
    is $advertiser->_order_details([$order])->[0]->{is_seen}, 0, 'seller is_seen flag is 0';

    # after seller call p2p_order_info when status is refunded
    is $advertiser->p2p_order_info(id => $order_id)->{is_seen}, 1, 'seller is_seen flag is 1';

    $advertiser->p2p_resolve_order_dispute(
        id     => $order_id,
        action => 'refund',
        staff  => 'x'
    );

    # after dispute resolved
    is $advertiser->p2p_order_info(id => $order_id)->{is_seen}, undef, 'is_seen flag not returned to seller';
    is $client->p2p_order_info(id => $order_id)->{is_seen},     undef, 'is_seen flag not returned to buyer';

};

done_testing();
