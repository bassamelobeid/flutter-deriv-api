use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;

use BOM::User::Client;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $email = 'p2p_offers_test@binary.com';

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
    type             => 'buy',
    account_currency => 'usd',
    local_currency   => 'myr',
    amount           => 100,
    price            => 1.23,
    min_amount       => 0.1,
    max_amount       => 10,
    method           => 'camels',
    description      => 'test offer',
    country          => 'ID'
);

like(
    exception {
        $test_client_cr->p2p_offer_create(%params)
    },
    qr/AgentNotActive/,
    "non agent can't create offer"
);
cmp_ok $test_client_cr->p2p_agent_create('agent1')->{client_loginid}, 'eq', $test_client_cr->loginid, "create agent";
ok !$test_client_cr->p2p_agent->{is_authenticated}, "agent not authenticated";
ok $test_client_cr->p2p_agent->{is_active}, "agent is active";
cmp_ok $test_client_cr->p2p_agent->{name}, 'eq', 'agent1', "agent name";
like(
    exception {
        $test_client_cr->p2p_agent_create('agent1')
    },
    qr/AlreadyRegistered/,
    "duplicate agent request not allowed"
);
like(
    exception {
        $test_client_cr->p2p_offer_create(%params)
    },
    qr/AgentNotAuthenticated/,
    "non auth can't create offer"
);
ok $test_client_cr->p2p_agent_update(auth => 1)->{is_authenticated}, "set agent authenticated";
is $test_client_cr->p2p_agent_update(name => 'testing')->{name}, 'testing', "set agent authenticated";

my $offer;
is(
    exception {
        $offer = $test_client_cr->p2p_offer_create(%params);
    },
    undef,
    "create offer successfully"
);

cmp_deeply(
    $offer,
    {
        id               => re('\d+'),
        account_currency => uc($params{account_currency}),
        local_currency   => $params{local_currency},
        is_active        => bool(1),
        agent_id         => $test_client_cr->p2p_agent->{id},
        created_time     => bool(1),
        amount           => num($params{amount}),
        remaining        => num($params{amount}),
        price            => num($params{price}),
        min_amount       => num($params{min_amount}),
        max_amount       => num($params{max_amount}),
        method           => $params{method},
        type             => $params{type},
        country          => $params{country},
        description      => $params{description}
    },
    "offer matches params"
);

cmp_deeply(
    $test_client_cr->p2p_offer_list,
    [{
            id               => re('\d+'),
            account_currency => uc($params{account_currency}),
            local_currency   => $params{local_currency},
            is_active        => bool(1),
            agent_id         => $test_client_cr->p2p_agent->{id},
            created_time     => bool(1),
            amount           => num($params{amount}),
            remaining        => num($params{amount}),
            price            => num($params{price}),
            min_amount       => num($params{min_amount}),
            max_amount       => num($params{max_amount}),
            method           => $params{method},
            type             => $params{type},
            country          => $params{country},
            description      => $params{description},
            agent_loginid    => $test_client_cr->loginid,
            agent_name       => 'testing'
        }
    ],
    "p2p_offer_list() returns correct info"
);

$test_client_cr->set_default_account('USD');

ok !$test_client_cr->p2p_offer_update(
    id     => $offer->{id},
    active => 0
)->{is_active}, "deactivate offer";
ok !$test_client_cr->p2p_offer($offer->{id})->{is_active}, "offer is inactive";
like(
    exception {
        $test_client_cr->p2p_offer_update(
            id     => $offer->{id},
            amount => 200
            )
    },
    qr/OfferNoEditInactive/,
    "can't edit inactive offer"
);
ok $test_client_cr->p2p_offer_update(
    id     => $offer->{id},
    active => 1
)->{is_active}, "reactivate offer";
cmp_ok $test_client_cr->p2p_offer_update(
    id     => $offer->{id},
    amount => 80
)->{amount}, '==', 80, "can edit active offer";

like(exception { $test_client_cr->p2p_offer_update(id => $offer->{id}, amount => 200) }, qr/MaximumExceeded/, "Can't update amount more than limit",);

BOM::Test::Helper::Client::top_up($test_client_cr, 'USD', 1000);
BOM::Test::Helper::P2P::create_escrow();

my ($order_client, $order) = BOM::Test::Helper::P2P::create_order(
    offer_id => $offer->{id},
    amount   => 70
);
cmp_ok $test_client_cr->p2p_offer_update(
    id     => $offer->{id},
    amount => 90
)->{amount}, '==', 90, "can change offer amount within available range";
like(
    exception {
        $test_client_cr->p2p_offer_update(
            id     => $offer->{id},
            amount => 50
            )
    },
    qr/OfferNoEditAmount/,
    "can't change offer amount below available range"
);
$order_client->p2p_order_cancel(id => $offer->{id});
cmp_ok $test_client_cr->p2p_offer_update(
    id     => $offer->{id},
    amount => 50
)->{amount}, '==', 50, "available range excludes cancelled orders";

$params{account_currency} = 'EUR';
like(
    exception {
        $test_client_cr->p2p_offer_create(%params)
    },
    qr/InvalidOfferCurrency/,
    "wrong currency can't create offer"
);
$params{account_currency} = 'USD';

ok !$test_client_cr->p2p_agent_update(active => 0)->{is_active}, "set agent inactive";

like(
    exception {
        $test_client_cr->p2p_offer_create(%params)
    },
    qr/AgentNotActive/,
    "inactive agent can't create offer"
);

done_testing();
