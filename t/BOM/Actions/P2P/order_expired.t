use strict;
use warnings;

use Test::More;
use BOM::Event::Actions::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::P2P;

use JSON::MaybeUTF8 qw(decode_json_utf8);

BOM::Test::Helper::P2P::bypass_sendbird();

subtest pending_order_expiry => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => 100,
        type   => 'sell'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => 100
    );
    BOM::Test::Helper::P2P::expire_order($client, $order->{id});

    BOM::Event::Actions::P2P::order_expired({
        client_loginid => $client->loginid,
        order_id       => $order->{id},
    });

    my $update_order = $client->p2p_order_info(id => $order->{id});
    is $update_order->{status}, 'refunded', "Got expected status";

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest client_confirmed_order_expiry => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => 100,
        type   => 'sell'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => 100
    );

    $client->p2p_order_confirm(id => $order->{id});
    BOM::Test::Helper::P2P::expire_order($client, $order->{id});

    BOM::Event::Actions::P2P::order_expired({
        client_loginid => $client->loginid,
        order_id       => $order->{id},
    });

    my $update_order = $client->p2p_order_info(id => $order->{id});
    is $update_order->{status}, 'timed-out', "Got expected status";

    BOM::Test::Helper::P2P::reset_escrow();
};

for my $test_status (qw(completed cancelled refunded timed-out blocked)) {
    subtest "${test_status}_order_expiry" => sub {
        my $escrow = BOM::Test::Helper::P2P::create_escrow();
        my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
            amount => 100,
            type   => 'sell'
        );
        my ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            amount    => 100
        );

        BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, $test_status);
        BOM::Test::Helper::P2P::expire_order($client, $order->{id});

        BOM::Event::Actions::P2P::order_expired({
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        });

        my $update_order = $client->p2p_order_info(id => $order->{id});
        is $update_order->{status}, $test_status, "Got expected status";

        BOM::Test::Helper::P2P::reset_escrow();
    };
}

done_testing();
