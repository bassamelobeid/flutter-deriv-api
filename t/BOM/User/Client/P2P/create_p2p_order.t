use strict;
use warnings;

use Test::More;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use Test::Fatal;

subtest 'Creating new order' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $order_data = $client->p2p_order_create(
        offer_id    => $offer->{id},
        amount      => 100,
        expiry      => 7200,
        description => $description
    );

    ok($order_data, 'Order is created');

    ok($escrow->account->balance == $amount, 'Money is deposited to Escrow account');
    ok($agent->account->balance == 0,        'Money is withdrawn from Agent account');

    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{amount} == $amount, 'Amount for new order is correct');
    is($order_data->{client_loginid}, $client->loginid, 'Client for new order is correct');
    is($order_data->{agent_loginid},  $agent->loginid,  'Agent for new order is correct');
    is($order_data->{description},    $description,     'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();

    cmp_deeply(
        $client->p2p_order_list,
        [{
                'id'                     => $order_data->{id},
                'agent_confirmed'        => $order_data->{agent_confirmed},
                'amount'                 => $order_data->{amount},
                'client_confirmed'       => $order_data->{client_confirmed},
                'client_loginid'         => $order_data->{client_loginid},
                'created_time'           => $order_data->{created_time},
                'description'            => $order_data->{description},
                'expire_time'            => $order_data->{expire_time},
                'status'                 => $order_data->{status},
                'agent_id'               => $agent->p2p_agent->{id},
                'agent_loginid'          => $agent->loginid,
                'agent_name'             => $agent->p2p_agent->{name},
                'offer_account_currency' => $offer->{account_currency},
                'offer_id'               => $offer->{id},
                'offer_local_currency'   => $offer->{local_currency},
                'offer_price'            => $offer->{price},
                'offer_type'             => $offer->{type}}
        ],
        'order_list() returns correct info'
    );
};

subtest 'Creating two orders from two clients' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client1 = BOM::Test::Helper::P2P::create_client();
    my $client2 = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $order_data1 = $client1->p2p_order_create(
        offer_id    => $offer->{id},
        amount      => 50,
        expiry      => 7200,
        description => $description
    );

    ok($order_data1, 'Order is created');

    ok($escrow->account->balance == 50, 'Money is deposited to Escrow account for first order');
    ok($agent->account->balance == 50,  'Money is withdrawn from Agent account for first order');

    is($order_data1->{status}, 'pending', 'Status for new order is correct');
    ok($order_data1->{amount} == 50, 'Amount for new order is correct');
    is($order_data1->{client_loginid}, $client1->loginid, 'Client for new order is correct');
    is($order_data1->{agent_loginid},  $agent->loginid,   'Agent for new order is correct');
    is($order_data1->{description},    $description,      'Description for new order is correct');

    my $order_data2 = $client2->p2p_order_create(
        offer_id    => $offer->{id},
        amount      => 50,
        expiry      => 7200,
        description => $description
    );

    ok($order_data2, 'Order is created');

    ok($escrow->account->balance == 100, 'Money is deposited to Escrow account for second order');
    ok($agent->account->balance == 0,    'Money is withdrawn from Agent account for second order');

    is($order_data2->{status}, 'pending', 'Status for new order is correct');
    ok($order_data2->{amount} == 50, 'Amount for new order is correct');
    is($order_data2->{client_loginid}, $client2->loginid, 'Client for new order is correct');
    is($order_data2->{agent_loginid},  $agent->loginid,   'Agent for new order is correct');
    is($order_data2->{description},    $description,      'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating two orders from one client for two offers' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent1, $offer1) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my ($agent2, $offer2) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,       'Escrow balance is correct');
    ok($agent1->account->balance == $amount, 'Agent balance is correct');
    ok($agent2->account->balance == $amount, 'Agent balance is correct');

    my $order_data1 = $client->p2p_order_create(
        offer_id    => $offer1->{id},
        amount      => 100,
        expiry      => 7200,
        description => $description
    );

    ok($order_data1, 'Order is created');

    ok($escrow->account->balance == 100, 'Money is deposited to Escrow account for first order');
    ok($agent1->account->balance == 0,   'Money is withdrawn from Agent account for first order');

    is($order_data1->{status}, 'pending', 'Status for new order is correct');
    ok($order_data1->{amount} == 100, 'Amount for new order is correct');
    is($order_data1->{client_loginid}, $client->loginid, 'Client for new order is correct');
    is($order_data1->{agent_loginid},  $agent1->loginid, 'Agent for new order is correct');
    is($order_data1->{description},    $description,     'Description for new order is correct');

    my $order_data2 = $client->p2p_order_create(
        offer_id    => $offer2->{id},
        amount      => 100,
        expiry      => 7200,
        description => $description
    );

    ok($order_data2, 'Order is created');

    ok($escrow->account->balance == 200, 'Money is deposited to Escrow account for second order');
    ok($agent2->account->balance == 0,   'Money is withdrawn from Agent account for second order');

    is($order_data2->{status}, 'pending', 'Status for new order is correct');
    ok($order_data2->{amount} == 100, 'Amount for new order is correct');
    is($order_data2->{client_loginid}, $client->loginid, 'Client for new order is correct');
    is($order_data2->{agent_loginid},  $agent2->loginid, 'Agent for new order is correct');
    is($order_data2->{description},    $description,     'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating two new orders from one client for one offer' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();

    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $order_data = $client->p2p_order_create(
        offer_id    => $offer->{id},
        amount      => 50,
        expiry      => 7200,
        description => $description
    );

    ok($order_data, 'Order is created');

    ok($escrow->account->balance == 50, 'Money is deposited to Escrow account for first order');
    ok($agent->account->balance == 50,  'Money is withdrawn from Agent account for first order');

    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{amount} == 50, 'Amount for new order is correct');
    is($order_data->{client_loginid}, $client->loginid, 'Client for new order is correct');
    is($order_data->{agent_loginid},  $agent->loginid,  'Agent for new order is correct');
    is($order_data->{description},    $description,     'Description for new order is correct');

    my $err = exception {
        $client->p2p_order_create(
            offer_id    => $offer->{id},
            amount      => 50,
            expiry      => 7200,
            description => $description
        );
    };
    chomp $err;
    is $err, 'OrderAlreadyExists', 'Got correct error';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order for agent own order' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $agent->p2p_order_create(
            offer_id    => $offer->{id},
            amount      => 100,
            expiry      => 7200,
            description => $description
        );
    };
    chomp($err);
    note explain $err;
    is $err, 'InvalidOfferOwn', 'Got correct error code';

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order with amount more than avalible' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $client->p2p_order_create(
            offer_id    => $offer->{id},
            amount      => 101,
            expiry      => 7200,
            description => $description
        );
    };

    chomp($err);
    is $err, 'MaximumExceeded', 'Got correct error code';

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order with negative amount' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $client->p2p_order_create(
            offer_id    => $offer->{id},
            amount      => -1,
            expiry      => 7200,
            description => $description
        );
    };

    chomp($err);
    is $err, 'MinimumNotMet', 'Got correct error code';

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order with disabled agent' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    $agent->p2p_agent_update(active => 0);

    my $err = exception {
        $client->p2p_order_create(
            offer_id    => $offer->{id},
            amount      => $amount,
            expiry      => 7200,
            description => $description
        );
    };

    chomp($err);
    is $err, 'OfferOwnerNotAuthenticated', 'Got correct error code';

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order without escrow' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $client->p2p_order_create(
            offer_id    => $offer->{id},
            amount      => $amount,
            expiry      => 7200,
            description => $description
        );
    };

    chomp($err);
    is $err, 'EscrowNotFound', 'Got correct error code';

    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

done_testing();
