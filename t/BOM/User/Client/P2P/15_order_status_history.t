use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

BOM::Test::Helper::P2P::bypass_sendbird();

BOM::Test::Helper::P2P::create_escrow();

my $advertiser_names = {
    first_name => 'juan',
    last_name  => 'perez'
};
my $client_names = {
    first_name => 'maria',
    last_name  => 'juana'
};

my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(advertiser => {%$advertiser_names});
my $client = BOM::Test::Helper::P2P::create_advertiser(client_details => {%$client_names});

my $order = $client->p2p_order_create(
    advert_id => $advert->{id},
    amount    => 4
);

my @statuses       = qw/timed-out pending timed-out disputed disputed dispute-refunded dispute-completed/;
my $stack          = [qw/pending/];
my $current_status = 'pending';

foreach my $status (@statuses) {
    BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, $status);

    # This check prevents to stack a consecutive repeated status
    push @$stack, $status if $status ne $current_status;
    $current_status = $status;

    my $list = $client->p2p_order_status_history($order->{id});

    my $expected = [map { +{stamp => re('.*'), status => $_,} } $stack->@*];

    cmp_deeply($list, $expected, 'The history status is correct after ' . $status);
}

BOM::Test::Helper::P2P::reset_escrow();

done_testing;
