use strict;
use warnings;

use Test::More;
use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

BOM::Test::Helper::P2P::bypass_sendbird();

BOM::Test::Helper::P2P::create_escrow();

my $advertiser_names = { first_name => 'john', last_name  => 'smith' };
my $client_names = { first_name => 'mary', last_name  => 'jane' };

my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(advertiser => { %$advertiser_names });
my $client = BOM::Test::Helper::P2P::create_advertiser(client_details => { %$client_names });

my $order = $client->p2p_order_create(advert_id=>$advert->{id}, amount=>10);

my $testit = sub {
    my ($order, $desc) = @_;
    is $order->{client_details}{first_name}, undef, "$desc client first_name is undef";
    is $order->{client_details}{last_name}, undef, "$desc client last_name is undef";
    is $order->{advertiser_details}{first_name}, undef, "$desc advertiser first_name is undef";
    is $order->{advertiser_details}{last_name}, undef, "$desc advertiser last_name is undef";        
};

$testit->($order, 'order create');
$testit->($client->p2p_order_info(id=>$order->{id}), 'p2p_order_info for client');
$testit->($advertiser->p2p_order_info(id=>$order->{id}), 'p2p_order_info for advertiser');
$testit->($client->p2p_order_list(id=>$order->{id})->[0], 'p2p_order_list for client');
$testit->($advertiser->p2p_order_list(id=>$order->{id})->[0], 'p2p_order_list for advertiser');    

BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
$order = $client->p2p_create_order_dispute(
        id             => $order->{id},
        dispute_reason => 'seller_not_released',
    );
$testit->($order, 'disputed order');


$client->p2p_advertiser_update(show_name=>1);
$advertiser->p2p_advertiser_update(show_name=>1);

$order = $client->p2p_order_create(advert_id=>$advert->{id}, amount=>10);

$testit = sub {
    my ($order, $desc) = @_;
    is $order->{client_details}{first_name}, $client_names->{first_name}, "$desc client first_name returned";
    is $order->{client_details}{last_name}, $client_names->{last_name}, "$desc client last_name returned";
    is $order->{advertiser_details}{first_name}, $advertiser_names->{first_name}, "$desc advertiser first_name returned";
    is $order->{advertiser_details}{last_name}, $advertiser_names->{last_name}, "$desc advertiser last_name returned";        
};

$testit->($order, 'order create');
$testit->($client->p2p_order_info(id=>$order->{id}), 'p2p_order_info for client');
$testit->($advertiser->p2p_order_info(id=>$order->{id}), 'p2p_order_info for advertiser');
$testit->($client->p2p_order_list(id=>$order->{id})->[0], 'p2p_order_list for client');
$testit->($advertiser->p2p_order_list(id=>$order->{id})->[0], 'p2p_order_list for advertiser');  

BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
$order = $client->p2p_create_order_dispute(
        id             => $order->{id},
        dispute_reason => 'seller_not_released',
    );
$testit->($order, 'disputed order');

BOM::Test::Helper::P2P::reset_escrow();

done_testing;
