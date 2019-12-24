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

my %offer_params = (
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

my %params = %offer_params;

subtest 'Creating offer from non-agent' => sub {
    my %params = %offer_params;

    my $client = BOM::Test::Helper::P2P::create_client();
    like(exception { $client->p2p_offer_create(%params) }, qr/AgentNotActive/, "non agent can't create offer");

};

subtest 'Agent Registration' => sub {
    my $client = BOM::Test::Helper::P2P::create_client();
    cmp_ok $client->p2p_agent_create('agent1')->{client_loginid}, 'eq', $client->loginid, "create agent";
    ok !$client->p2p_agent->{is_authenticated}, "agent not authenticated";
    ok $client->p2p_agent->{is_active}, "agent is active";
    cmp_ok $client->p2p_agent->{name}, 'eq', 'agent1', "agent name";
};

subtest 'Dublicate Agent Registration' => sub {
    my $agent = BOM::Test::Helper::P2P::create_agent();

    like(
        exception {
            $agent->p2p_agent_create('agent1')
        },
        qr/AlreadyRegistered/,
        "duplicate agent request not allowed"
    );
};

subtest 'Creating offer from not authenticated agent' => sub {
    my $agent = BOM::Test::Helper::P2P::create_agent();
    $agent->p2p_agent_update(auth => 0);

    like(
        exception {
            $agent->p2p_offer_create(%params)
        },
        qr/AgentNotAuthenticated/,
        "non auth can't create offer"
    );
};

subtest 'Updating agent fields' => sub {
    my $agent = BOM::Test::Helper::P2P::create_agent();

    ok $agent->p2p_agent->{is_authenticated}, 'Agent is authenticated';
    is $agent->p2p_agent->{name},             '', 'Agent is authenticated';
    ok $agent->p2p_agent->{is_active},        'Agent is active';

    ok !($agent->p2p_agent_update(auth => 0)->{is_authenticated}), 'Disable authentucation';
    is $agent->p2p_agent_update(name => 'test')->{name}, 'test', 'Changing name';
    ok !($agent->p2p_agent_update(active => 0)->{is_active}), 'Switch flag active to false';

    ok $agent->p2p_agent_update(auth   => 1)->{is_authenticated}, 'Enabling authentucation';
    ok $agent->p2p_agent_update(active => 1)->{is_active},        'Switch flag active to true';
};

subtest 'Creating offer successfully' => sub {
    my %params = %offer_params;
    my $agent  = BOM::Test::Helper::P2P::create_agent();
    $agent->p2p_agent_update(name => 'testing');

    my $offer;
    is(
        exception {
            $offer = $agent->p2p_offer_create(%params);
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
            agent_id         => $agent->p2p_agent->{id},
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
        $agent->p2p_offer_list,
        [{
                id               => re('\d+'),
                account_currency => uc($params{account_currency}),
                local_currency   => $params{local_currency},
                is_active        => bool(1),
                agent_id         => $agent->p2p_agent->{id},
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
                agent_loginid    => $agent->loginid,
                agent_name       => 'testing'
            }
        ],
        "p2p_offer_list() returns correct info"
    );
};

subtest 'Updating offer' => sub {
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => 100);

    ok $offer->{is_active}, 'Offer is active';

    ok !$agent->p2p_offer_update(
        id     => $offer->{id},
        active => 0
    )->{is_active}, "Deactivate offer";

    ok !$agent->p2p_offer($offer->{id})->{is_active}, "offer is inactive";

    #TODO: Not sure that, this test case is valid, moving it as is. but we need to check it.
    # I think only not active offers could be updatble.
    like(
        exception {
            $agent->p2p_offer_update(
                id     => $offer->{id},
                amount => 200
                )
        },
        qr/OfferNoEditInactive/,
        "can't edit inactive offer"
    );

    ok $agent->p2p_offer_update(
        id     => $offer->{id},
        active => 1
    )->{is_active}, "reactivate offer";
    cmp_ok $agent->p2p_offer_update(
        id     => $offer->{id},
        amount => 80
    )->{amount}, '==', 80, "can edit active offer";

    like(exception { $agent->p2p_offer_update(id => $offer->{id}, amount => 200) }, qr/MaximumExceeded/, "Can't update amount more than limit",);
};

subtest 'Updating order with avalible range' => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => 100);

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
    $order_client->p2p_order_cancel(id => $order->{id});
    cmp_ok $test_client_cr->p2p_offer_update(
        id     => $offer->{id},
        amount => 50
    )->{amount}, '==', 50, "available range excludes cancelled orders";
    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating offer with invalid currency' => sub {
    my %params = %offer_params;
    my $agent  = BOM::Test::Helper::P2P::create_agent();

    $params{account_currency} = 'EUR';
    like(
        exception {
            $agent->p2p_offer_create(%params)
        },
        qr/InvalidOfferCurrency/,
        "wrong currency can't create offer"
    );
};

subtest 'Creating offer from non active agent' => sub {
    my %params = %offer_params;
    my $agent  = BOM::Test::Helper::P2P::create_agent();
    ok !$agent->p2p_agent_update(active => 0)->{is_active}, "set agent inactive";

    like(
        exception {
            $agent->p2p_offer_create(%params)
        },
        qr/AgentNotActive/,
        "inactive agent can't create offer"
    );
};

done_testing();
