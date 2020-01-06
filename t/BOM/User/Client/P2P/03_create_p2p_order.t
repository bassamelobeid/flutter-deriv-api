use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;
use Format::Util::Numbers qw(formatnumber);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use Test::Fatal;

subtest 'Creating new order' => sub {
    my $amount      = 100;
    my $description = 'Test order';

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $order_data = $client->p2p_order_create(
        offer_id    => $offer->{offer_id},
        amount      => 100,
        expiry      => 7200,
        description => $description
    );

    ok($order_data, 'Order is created');

    ok($escrow->account->balance == $amount, 'Money is deposited to Escrow account');
    ok($agent->account->balance == 0,        'Money is withdrawn from Agent account');

    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{order_amount} == $amount, 'Amount for new order is correct');
    is($order_data->{client_loginid},    $client->loginid, 'Client for new order is correct');
    is($order_data->{agent_loginid},     $agent->loginid,  'Agent for new order is correct');
    is($order_data->{order_description}, $description,     'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
    cmp_deeply(
        $client->p2p_order_list,
        [{
                'order_id'               => $order_data->{order_id},
                'agent_confirmed'        => $order_data->{agent_confirmed},
                'order_amount'           => $order_data->{order_amount},
                'client_confirmed'       => $order_data->{client_confirmed},
                'client_loginid'         => $order_data->{client_loginid},
                'created_time'           => $order_data->{created_time},
                'order_description'      => $order_data->{order_description},
                'expire_time'            => $order_data->{expire_time},
                'is_expired'             => bool(0),
                'status'                 => $order_data->{status},
                'agent_id'               => $agent->p2p_agent->{id},
                'agent_loginid'          => $agent->loginid,
                'agent_name'             => $agent->p2p_agent->{name},
                'offer_account_currency' => $offer->{account_currency},
                'offer_id'               => $offer->{offer_id},
                'offer_local_currency'   => $offer->{local_currency},
                'offer_rate'             => $offer->{rate},
                'offer_type'             => $offer->{type},
                'offer_description'      => $offer->{offer_description}}
        ],
        'order_list() returns correct info'
    );
};

subtest 'Creating two orders from two clients' => sub {
    my $amount      = 100;
    my $description = 'Test order';

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client1 = BOM::Test::Helper::P2P::create_client();
    my $client2 = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $order_data1 = $client1->p2p_order_create(
        offer_id    => $offer->{offer_id},
        amount      => 50,
        expiry      => 7200,
        description => $description
    );

    ok($order_data1, 'Order is created');

    ok($escrow->account->balance == 50, 'Money is deposited to Escrow account for first order');
    ok($agent->account->balance == 50,  'Money is withdrawn from Agent account for first order');

    is($order_data1->{status}, 'pending', 'Status for new order is correct');
    ok($order_data1->{order_amount} == 50, 'Amount for new order is correct');
    is($order_data1->{client_loginid},    $client1->loginid, 'Client for new order is correct');
    is($order_data1->{agent_loginid},     $agent->loginid,   'Agent for new order is correct');
    is($order_data1->{order_description}, $description,      'Description for new order is correct');

    my $order_data2 = $client2->p2p_order_create(
        offer_id    => $offer->{offer_id},
        amount      => 50,
        expiry      => 7200,
        description => $description
    );

    ok($order_data2, 'Order is created');

    ok($escrow->account->balance == 100, 'Money is deposited to Escrow account for second order');
    ok($agent->account->balance == 0,    'Money is withdrawn from Agent account for second order');

    is($order_data2->{status}, 'pending', 'Status for new order is correct');
    ok($order_data2->{order_amount} == 50, 'Amount for new order is correct');
    is($order_data2->{client_loginid},    $client2->loginid, 'Client for new order is correct');
    is($order_data2->{agent_loginid},     $agent->loginid,   'Agent for new order is correct');
    is($order_data2->{order_description}, $description,      'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating two orders from one client for two offers' => sub {
    my $amount      = 100;
    my $description = 'Test order';

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent1, $offer1) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my ($agent2, $offer2) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,       'Escrow balance is correct');
    ok($agent1->account->balance == $amount, 'Agent balance is correct');
    ok($agent2->account->balance == $amount, 'Agent balance is correct');

    my $order_data1 = $client->p2p_order_create(
        offer_id    => $offer1->{offer_id},
        amount      => 100,
        expiry      => 7200,
        description => $description
    );

    ok($order_data1, 'Order is created');

    ok($escrow->account->balance == 100, 'Money is deposited to Escrow account for first order');
    ok($agent1->account->balance == 0,   'Money is withdrawn from Agent account for first order');

    is($order_data1->{status}, 'pending', 'Status for new order is correct');
    ok($order_data1->{order_amount} == 100, 'Amount for new order is correct');
    is($order_data1->{client_loginid},    $client->loginid, 'Client for new order is correct');
    is($order_data1->{agent_loginid},     $agent1->loginid, 'Agent for new order is correct');
    is($order_data1->{order_description}, $description,     'Description for new order is correct');

    my $order_data2 = $client->p2p_order_create(
        offer_id    => $offer2->{offer_id},
        amount      => 100,
        expiry      => 7200,
        description => $description
    );

    ok($order_data2, 'Order is created');

    ok($escrow->account->balance == 200, 'Money is deposited to Escrow account for second order');
    ok($agent2->account->balance == 0,   'Money is withdrawn from Agent account for second order');

    is($order_data2->{status}, 'pending', 'Status for new order is correct');
    ok($order_data2->{order_amount} == 100, 'Amount for new order is correct');
    is($order_data2->{client_loginid},    $client->loginid, 'Client for new order is correct');
    is($order_data2->{agent_loginid},     $agent2->loginid, 'Agent for new order is correct');
    is($order_data2->{order_description}, $description,     'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating two new orders from one client for one offer' => sub {
    my $amount      = 100;
    my $description = 'Test order';

    my $escrow = BOM::Test::Helper::P2P::create_escrow();

    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $order_data = $client->p2p_order_create(
        offer_id    => $offer->{offer_id},
        amount      => 50,
        expiry      => 7200,
        description => $description
    );

    ok($order_data, 'Order is created');

    ok($escrow->account->balance == 50, 'Money is deposited to Escrow account for first order');
    ok($agent->account->balance == 50,  'Money is withdrawn from Agent account for first order');

    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{order_amount} == 50, 'Amount for new order is correct');
    is($order_data->{client_loginid},    $client->loginid, 'Client for new order is correct');
    is($order_data->{agent_loginid},     $agent->loginid,  'Agent for new order is correct');
    is($order_data->{order_description}, $description,     'Description for new order is correct');

    my $err = exception {
        $client->p2p_order_create(
            offer_id    => $offer->{offer_id},
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

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $agent->p2p_order_create(
            offer_id    => $offer->{offer_id},
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

subtest 'Creating order with amount more than available' => sub {
    my $amount      = 100;
    my $description = 'Test order';

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $client->p2p_order_create(
            offer_id    => $offer->{offer_id},
            amount      => 101,
            expiry      => 7200,
            description => $description
        );
    };

    is $err->{error_code}, 'OrderMaximumExceeded', 'Got correct error code';

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order with negative amount' => sub {
    my $amount      = 100;
    my $description = 'Test order';

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $client->p2p_order_create(
            offer_id    => $offer->{offer_id},
            amount      => -1,
            expiry      => 7200,
            description => $description
        );
    };

    is $err->{error_code}, 'OrderMinimumNotMet', 'Got correct error code';

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order outside min-max range' => sub {
    my $amount      = 100;
    my $min_amount  = 20;
    my $max_amount  = 50;
    my $description = 'Test order';

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(
        amount     => $amount,
        min_amount => $min_amount,
        max_amount => $max_amount,
    );
    my $account_currency = $agent->account->currency_code;
    my $client           = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $client->p2p_order_create(
            offer_id    => $offer->{offer_id},
            amount      => $min_amount - 1,
            expiry      => 7200,
            description => $description
        );
    };

    is $err->{error_code}, 'OrderMinimumNotMet', 'Got correct error code';
    cmp_bag($err->{message_params}, [$account_currency, formatnumber('amount', $account_currency, $min_amount)], 'Got correct error values');

    $err = exception {
        $client->p2p_order_create(
            offer_id    => $offer->{offer_id},
            amount      => $max_amount + 1,
            expiry      => 7200,
            description => $description
        );
    };

    is $err->{error_code}, 'OrderMaximumExceeded', 'Got correct error code';
    cmp_bag($err->{message_params}, [$account_currency, formatnumber('amount', $account_currency, $max_amount)], 'Got correct error values');

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order with disabled agent' => sub {
    my $amount      = 100;
    my $description = 'Test order';

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    $agent->p2p_agent_update(active => 0);

    my $err = exception {
        $client->p2p_order_create(
            offer_id    => $offer->{offer_id},
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

    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $client->p2p_order_create(
            offer_id    => $offer->{offer_id},
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

subtest 'Sell offers' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(
        amount => $amount,
        type   => 'sell'
    );
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0, 'Escrow balance is correct');
    ok($agent->account->balance == 0,  'Agent balance is correct');
    note $agent->account->balance;
    my %params = (
        offer_id    => $offer->{offer_id},
        amount      => 100,
        expiry      => 7200,
        description => $description
    );
    my $err = exception {
        warning_like { $client->p2p_order_create(%params) } qr/check_no_negative_balance/;
    };
    like $err, qr/InsufficientBalance/, 'error for insufficient client balance';

    BOM::Test::Helper::Client::top_up($client, $client->currency, $amount);

    my $order_data = $client->p2p_order_create(%params);

    ok($order_data, 'Order is created');

    ok($escrow->account->balance == $amount, 'Money is deposited to Escrow account');
    ok($client->account->balance == 0,       'Money is withdrawn from Client account');

    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{order_amount} == $amount, 'Amount for new order is correct');
    is($order_data->{client_loginid},    $client->loginid, 'Client for new order is correct');
    is($order_data->{agent_loginid},     $agent->loginid,  'Agent for new order is correct');
    is($order_data->{order_description}, $description,     'Description for new order is correct');
    is($order_data->{offer_type},        'sell',           'offer type is sell');

    BOM::Test::Helper::P2P::reset_escrow();

};

done_testing();
