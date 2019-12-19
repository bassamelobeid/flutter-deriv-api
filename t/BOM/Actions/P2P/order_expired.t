use strict;
use warnings;

use Test::More;
use feature 'state';
use BOM::Event::Actions::P2P;

use BOM::Test;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Config::Runtime;
use Data::Dumper;
use BOM::Database::ClientDB;
use BOM::Config::RedisReplicated;
use BOM::Test::Helper::P2P;

use JSON::MaybeUTF8 qw(decode_json_utf8);

subtest pending_order_expiry => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => 100);
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        offer_id => $offer->{id},
        amount   => 100
    );

    BOM::Event::Actions::P2P::order_expired({
        client_loginid => $client->loginid,
        order_id       => $order->{id},
    });

    my $update_order = $client->p2p_order($order->{id});
    is $update_order->{status}, 'cancelled', "Got expected status";

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest client_confirmed_order_expiry => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => 100);
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        offer_id => $offer->{id},
        amount   => 100
    );

    $client->p2p_order_confirm(id => $order->{id});

    BOM::Event::Actions::P2P::order_expired({
        client_loginid => $client->loginid,
        order_id       => $order->{id},
    });

    my $update_order = $client->p2p_order($order->{id});

    is $update_order->{status}, 'cancelled', "Got expected status";

    BOM::Test::Helper::P2P::reset_escrow();
};

for my $test_status (qw(completed cancelled refunded timed-out)) {
    subtest "${test_status}_order_expiry" => sub {
        my $escrow = BOM::Test::Helper::P2P::create_escrow();
        my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => 100);
        my ($client, $order) = BOM::Test::Helper::P2P::create_order(
            offer_id => $offer->{id},
            amount   => 100
        );

        BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, $test_status);

        BOM::Event::Actions::P2P::order_expired({
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        });

        my $update_order = $client->p2p_order($order->{id});

        is $update_order->{status}, $test_status, "Got expected status";

        BOM::Test::Helper::P2P::reset_escrow();
    };
}

done_testing();
