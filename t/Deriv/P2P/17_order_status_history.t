use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::Test::Helper::P2P;
use BOM::Rules::Engine;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

=head2 

This test will verify if p2p_order_status_history subroutine returns order status history correctly:
1. Each status should only appear once
2. It should follow the sequence in which the order changes were inserted into audit.p2p_order table

When same status appear consecutively, only the first one should be returned based on earliest timestamp. 
However, we can't test this here because we can't control the timestamp of each status change in database.
This case will be covered in the pgTAP test for p2p.order_status_history database function.

=cut

my $advertiser_names = {
    first_name => 'juan',
    last_name  => 'perez'
};
my $client_names = {
    first_name => 'maria',
    last_name  => 'juana'
};

my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(advertiser => $advertiser_names);
my $client = BOM::Test::Helper::P2P::create_advertiser(client_details => $client_names);

my $test_cases = [{
        order_audit => [qw(pending pending pending buyer-confirmed buyer-confirmed timed-out timed-out completed)],
        expected    => [map { +{stamp => re('.*'), status => $_} } qw(pending buyer-confirmed timed-out completed)],
        desc        => "order completed normally after getting timed-out"
    },
    {
        order_audit => [qw(pending pending buyer-confirmed buyer-confirmed timed-out disputed disputed disputed completed completed)],
        expected    => [map { +{stamp => re('.*'), status => $_} } qw(pending buyer-confirmed timed-out disputed completed)],
        desc        => "order completed normally after getting disputed"
    },
    {
        order_audit => [qw(pending pending buyer-confirmed buyer-confirmed timed-out disputed disputed disputed dispute-completed dispute-completed)],
        expected    => [map { +{stamp => re('.*'), status => $_} } qw(pending buyer-confirmed timed-out disputed dispute-completed)],
        desc        => "order resolved in favor of buyer after getting disputed"
    },

];

foreach my $test_case (@$test_cases) {
    my $order = $client->p2p_order_create(
        advert_id   => $advert->{id},
        amount      => 4,
        rule_engine => BOM::Rules::Engine->new(),
    );
    foreach my $status (@{$test_case->{order_audit}}) {
        BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, $status);
    }

    my $list = $client->p2p_order_status_history($order->{id});
    cmp_deeply($list, $test_case->{expected}, "The order of history status is correct for: " . $test_case->{desc});

}

BOM::Test::Helper::P2P::reset_escrow();

done_testing;
