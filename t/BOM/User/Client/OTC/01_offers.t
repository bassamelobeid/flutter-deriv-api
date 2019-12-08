use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::Deep;
use BOM::User::Client;
use BOM::Test::Helper::OTC;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $email = 'otc_offers_test@binary.com';

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email
});

my $user = BOM::User->create(
    email    => $email,
    password => 'test'
);

$user->add_client($test_client_cr);

my %params = (
    type        => 'buy',
    currency    => 'usd',
    expiry      => 30,
    amount      => 100,
    price       => 1.23,
    min_amount  => 0.1,
    max_amount  => 10,
    method      => 'camels',
    description => 'test offer',
    country     => 'ID'
);

throws_ok { $test_client_cr->create_otc_offer(%params) } qr/AgentNotActive/, "non agent can't create offer";
cmp_ok $test_client_cr->new_otc_agent('agent1')->{client_loginid}, 'eq', $test_client_cr->loginid, "create agent";
ok !$test_client_cr->get_otc_agent->{is_authenticated}, "agent not authenticated";
ok $test_client_cr->get_otc_agent->{is_active}, "agent is active";
cmp_ok $test_client_cr->get_otc_agent->{name}, 'eq', 'agent1', "agent name";
throws_ok { $test_client_cr->new_otc_agent('agent1') } qr/AlreadyRegistered/, "duplicate agent request not allowed";
throws_ok { $test_client_cr->create_otc_offer(%params) } qr/AgentNotAuthenticated/, "non auth can't create offer";
ok $test_client_cr->update_otc_agent(auth => 1)->{is_authenticated}, "set agent authenticated";
is $test_client_cr->update_otc_agent(name => 'testing')->{name}, 'testing', "set agent authenticated";

my $offer;
lives_ok { $offer = $test_client_cr->create_otc_offer(%params); } "create offer successfully";

cmp_deeply(
    $offer,
    {
        id           => re('\d+'),
        currency     => uc($params{currency}),
        expire_time  => bool(1),
        is_active    => bool(1),
        agent_id     => $test_client_cr->get_otc_agent->{id},
        created_time => bool(1),
        amount       => num($params{amount}),
        price        => num($params{price}),
        min_amount   => num($params{min_amount}),
        max_amount   => num($params{max_amount}),
        method       => $params{method},
        type         => $params{type},
        country      => $params{country},
        description  => $params{description}
    },
    "offer matches params"
);

$test_client_cr->set_default_account('USD');

ok !$test_client_cr->update_otc_offer(
    id     => $offer->{id},
    active => 0
)->{is_active}, "deactivate offer";
ok !$test_client_cr->get_otc_offer($offer->{id})->{is_active}, "offer is inactive";
throws_ok { $test_client_cr->update_otc_offer(id => $offer->{id}, amount => 200) } qr/OfferNoEditInactive/, "can't edit inactive offer";
ok $test_client_cr->update_otc_offer(
    id     => $offer->{id},
    active => 1
)->{is_active}, "reactivate offer";
cmp_ok $test_client_cr->update_otc_offer(
    id     => $offer->{id},
    amount => 80
)->{amount}, '==', 80, "can edit active offer";

throws_ok { $test_client_cr->update_otc_offer(id => $offer->{id}, amount => 200) } qr/MaximumExceeded/,

BOM::Test::Helper::Client::top_up($test_client_cr, 'USD', 1000);
BOM::Test::Helper::OTC::create_escrow();

my ($order_client, $order) = BOM::Test::Helper::OTC::create_order(
    offer_id => $offer->{id},
    amount   => 70
);
cmp_ok $test_client_cr->update_otc_offer(
    id     => $offer->{id},
    amount => 90
)->{amount}, '==', 90, "can change offer amount within available range";
throws_ok { $test_client_cr->update_otc_offer(id => $offer->{id}, amount => 50) } qr/OfferNoEditAmount/,
    "can't change offer amount below available range";
$order_client->cancel_otc_order(id => $offer->{id});
cmp_ok $test_client_cr->update_otc_offer(
    id     => $offer->{id},
    amount => 50
)->{amount}, '==', 50, "available range excludes cancelled orders";
BOM::Test::Helper::OTC::expire_offer($test_client_cr, $offer->{id});
throws_ok { $test_client_cr->update_otc_offer(id => $offer->{id}, active => 0) } qr/OfferNoEditExpired/, "can't change expired offer";

$params{currency} = 'EUR';
throws_ok { $test_client_cr->create_otc_offer(%params) } qr/InvalidOfferCurrency/, "wrong currency can't create offer";
$params{currency} = 'USD';

ok !$test_client_cr->update_otc_agent(active => 0)->{is_active}, "set agent inactive";

throws_ok { $test_client_cr->create_otc_offer(%params) } qr/AgentNotActive/, "inactive agent can't create offer";

done_testing();
