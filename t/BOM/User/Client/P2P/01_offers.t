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

BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_offer(100);
BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([]);
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
    type              => 'buy',
    account_currency  => 'usd',
    local_currency    => 'myr',
    amount            => 100,
    rate              => 1.23,
    min_amount        => 0.1,
    max_amount        => 10,
    method            => 'camels',
    offer_description => 'test offer',
    country           => 'ID'
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

subtest 'Duplicate Agent Registration' => sub {
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
    $agent->p2p_agent_update(is_authenticated => 0);

    like(
        exception {
            $agent->p2p_offer_create(%params)
        },
        qr/AgentNotAuthenticated/,
        "non auth can't create offer"
    );
};

subtest 'Updating agent fields' => sub {
    my $agent_name = 'agent name';
    my $agent = BOM::Test::Helper::P2P::create_agent(agent_name => $agent_name);

    ok $agent->p2p_agent->{is_authenticated}, 'Agent is authenticated';
    is $agent->p2p_agent->{name},             $agent_name, 'Agent name is correct';
    ok $agent->p2p_agent->{is_active},        'Agent is active';

    like(
        exception {
            $agent->p2p_agent_update(agent_name => ' ');
        },
        qr/AgentNameRequired/,
        'Error when agent name is blank'
    );
    is $agent->p2p_agent_update(agent_name => 'test')->{name}, 'test', 'Changing name';
    ok !($agent->p2p_agent_update(is_active => 0)->{is_active}), 'Switch flag active to false';

    ok !($agent->p2p_agent_update(is_authenticated => 0)->{is_authenticated}), 'Disable authentication';
    like(
        exception {
            $agent->p2p_agent_update(is_active => 1);
        },
        qr/AgentNotAuthenticated/,
        'Error when agent is not authenticated'
    );

    ok $agent->p2p_agent_update(is_authenticated => 1)->{is_authenticated}, 'Enabling authentication';
    ok $agent->p2p_agent_update(is_active        => 1)->{is_active},        'Switch flag active to true';
};

subtest 'Creating offer' => sub {
    my %params = %offer_params;
    my $agent  = BOM::Test::Helper::P2P::create_agent();
    $agent->p2p_agent_update(agent_name => 'testing');

    my $offer;

    for my $numeric_field (qw(amount max_amount min_amount rate)) {
        %params = %offer_params;

        $params{$numeric_field} = -1;
        cmp_deeply(
            exception {
                $offer = $agent->p2p_offer_create(%params);
            },
            {
                error_code => 'InvalidNumericValue',
                details    => {fields => [$numeric_field]},
            },
            "Error when numeric field '$numeric_field' is not greater than 0"
        );
    }

    %params = %offer_params;
    $params{amount} = 200;
    like(
        exception {
            $offer = $agent->p2p_offer_create(%params);
        },
        qr/MaximumExceeded/,
        'Error when amount exceeds BO offer limit'
    );

    %params = %offer_params;
    my $maximum_order = BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_order;
    $params{max_amount} = $maximum_order + 1;
    cmp_deeply(
        exception {
            $agent->p2p_offer_create(%params);
        },
        {
            error_code     => 'MaxPerOrderExceeded',
            message_params => [uc $params{account_currency}, $maximum_order],
        },
        'Error when max_amount exceeds BO order limit'
    );

    %params = %offer_params;
    $params{min_amount} = $params{max_amount} + 1;
    like(
        exception {
            $offer = $agent->p2p_offer_create(%params);
        },
        qr/InvalidMinMaxAmount/,
        'Error when min_amount is more than max_amount'
    );

    %params = %offer_params;
    $params{amount} = $params{max_amount} - 1;
    like(
        exception {
            $offer = $agent->p2p_offer_create(%params);
        },
        qr/InvalidMaxAmount/,
        'Error when max_amount is more than amount'
    );

    %params = %offer_params;
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

            offer_id          => re('\d+'),
            account_currency  => uc($params{account_currency}),
            local_currency    => $params{local_currency},
            is_active         => bool(1),
            agent_id          => $agent->p2p_agent->{id},
            created_time      => bool(1),
            offer_amount      => num($params{amount}),
            remaining         => num($params{amount}),
            rate              => num($params{rate}),
            min_amount        => num($params{min_amount}),
            max_amount        => num($params{max_amount}),
            method            => $params{method},
            type              => $params{type},
            country           => $params{country},
            offer_description => $params{offer_description}
        },
        "offer matches params"
    );

    cmp_deeply(
        $agent->p2p_offer_list,
        [{
                offer_id          => re('\d+'),
                account_currency  => uc($params{account_currency}),
                local_currency    => $params{local_currency},
                is_active         => bool(1),
                agent_id          => $agent->p2p_agent->{id},
                created_time      => bool(1),
                offer_amount      => num($params{amount}),
                remaining         => num($params{amount}),
                rate              => num($params{rate}),
                min_amount        => num($params{min_amount}),
                max_amount        => num($params{max_amount}),
                method            => $params{method},
                type              => $params{type},
                country           => $params{country},
                offer_description => $params{offer_description},
                agent_loginid     => $agent->loginid,
                agent_name        => 'testing'
            }
        ],
        "p2p_offer_list() returns correct info"
    );
};

subtest 'Updating offer' => sub {
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(
        max_amount => 80,
        amount     => 100
    );
    ok $offer->{is_active}, 'Offer is active';

    my $client = BOM::Test::Helper::P2P::create_client();
    like(exception { $client->p2p_offer_update(offer_id => $offer->{offer_id}, is_active => 0) },
        qr/PermissionDenied/, "Other client cannot edit offer");

    ok !$agent->p2p_offer_update(
        offer_id  => $offer->{offer_id},
        is_active => 0
    )->{is_active}, "Deactivate offer";

    ok !$agent->p2p_offer($offer->{offer_id})->{is_active}, "offer is inactive";

    ok $agent->p2p_offer_update(
        offer_id  => $offer->{offer_id},
        is_active => 1
    )->{is_active}, "reactivate offer";

    cmp_ok $agent->p2p_offer_update(
        offer_id   => $offer->{offer_id},
        max_amount => 80,
        amount     => 80
    )->{offer_amount}, '==', 80, "Update amount";

    for my $numeric_field (qw(amount max_amount min_amount rate)) {
        cmp_deeply(
            exception {
                $agent->p2p_offer_update(
                    offer_id       => $offer->{offer_id},
                    $numeric_field => -1
                );
            },
            {
                error_code => 'InvalidNumericValue',
                details    => {fields => [$numeric_field]},
            },
            "Error when numeric field '$numeric_field' is not greater than 0"
        );
    }

    like(
        exception {
            $agent->p2p_offer_update(
                offer_id => $offer->{offer_id},
                amount   => 200
            );
        },
        qr/MaximumExceeded/,
        'Error when amount exceeds BO offer limit'
    );

    like(
        exception {
            $agent->p2p_offer_update(
                offer_id   => $offer->{offer_id},
                min_amount => 20,
                max_amount => 10
            );
        },
        qr/InvalidMinMaxAmount/,
        'Error when min_amount is more than max_amount'
    );

    %params = %offer_params;
    $params{amount} = $params{max_amount} - 1;
    like(
        exception {
            $agent->p2p_offer_update(
                offer_id   => $offer->{offer_id},
                max_amount => 100
            );    # offer amount is currently 80
        },
        qr/InvalidMaxAmount/,
        'Error when max_amount is more than amount'
    );

    my $empty_update = $agent->p2p_offer_update(offer_id => $offer->{offer_id});
    delete $empty_update->{amount};
    cmp_deeply($empty_update, $agent->p2p_offer($offer->{offer_id}), 'empty update');
};

subtest 'Updating order with available range' => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(
        max_amount => 50,
        amount     => 100
    );

    my ($order_client, $order) = BOM::Test::Helper::P2P::create_order(
        offer_id => $offer->{offer_id},
        amount   => 35
    );
    BOM::Test::Helper::P2P::create_order(
        offer_id => $offer->{offer_id},
        amount   => 35
    );
    cmp_ok $agent->p2p_offer_update(
        offer_id   => $offer->{offer_id},
        amount     => 90,
        max_amount => 10,
    )->{offer_amount}, '==', 90, "can change offer amount within available range";
    like(
        exception {
            $agent->p2p_offer_update(
                offer_id => $offer->{offer_id},
                amount   => 50
                )
        },
        qr/OfferInsufficientAmount/,
        "can't change offer amount below available range"
    );
    $order_client->p2p_order_cancel(id => $order->{order_id});
    cmp_ok $agent->p2p_offer_update(
        offer_id => $offer->{offer_id},
        amount   => 50
    )->{offer_amount}, '==', 50, "available range excludes cancelled orders";

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating offer from non active agent' => sub {
    my %params = %offer_params;
    my $agent  = BOM::Test::Helper::P2P::create_agent();
    ok !$agent->p2p_agent_update(is_active => 0)->{is_active}, "set agent inactive";

    like(
        exception {
            $agent->p2p_offer_create(%params)
        },
        qr/AgentNotActive/,
        "inactive agent can't create offer"
    );
};

done_testing();
