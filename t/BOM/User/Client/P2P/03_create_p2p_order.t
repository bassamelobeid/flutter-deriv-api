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

my $order_description = 'Test order';
BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([]);

subtest 'Creating new order' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $order_data = $client->p2p_order_create(
        offer_id          => $offer->{offer_id},
        amount            => 100,
        expiry            => 7200,
        order_description => $order_description
    );

    ok($order_data, 'Order is created');

    ok($escrow->account->balance == $amount, 'Money is deposited to Escrow account');
    ok($agent->account->balance == 0,        'Money is withdrawn from Agent account');

    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{amount} == $amount, 'Amount for new order is correct');
    is($order_data->{order_description}, $order_description, 'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
    
    my $expected_order = {
        'order_id'           => $order_data->{order_id},
        'amount'             => num($order_data->{amount}),
        'amount_display'     => num($order_data->{amount}),
        'price'              => num($order_data->{rate} * $order_data->{amount}),
        'price_display'      => num($order_data->{rate} * $order_data->{amount}),
        'rate'               => num($order_data->{rate}),
        'rate_display'       => num($order_data->{rate}),                     
        'created_time'       => re('\d+'),
        'expiry_time'        => re('\d+'),
        'order_description'  => $order_data->{order_description},
        'offer_description'  => $offer->{offer_description},
        'status'             => $order_data->{status},
        'agent_id'           => $agent->p2p_agent_info->{agent_id},
        'agent_name'         => $agent->p2p_agent_info->{agent_name},
        'account_currency'   => $offer->{account_currency},
        'offer_id'           => $offer->{offer_id},
        'local_currency'     => $offer->{local_currency},
        'type'               => $offer->{type},
    };
   
    cmp_deeply(
        $client->p2p_order_list,
        [ $expected_order ],
        'order_list() returns correct info'
    );
    
    cmp_deeply(
        $client->p2p_order_info(order_id => $order_data->{order_id}),
        $expected_order,
        'order_info() returns correct info'
    );
    
};

subtest 'Creating two orders from two clients' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client1 = BOM::Test::Helper::P2P::create_client();
    my $client2 = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $order_data1 = $client1->p2p_order_create(
        offer_id          => $offer->{offer_id},
        amount            => 50,
        expiry            => 7200,
        order_description => $order_description
    );

    ok($order_data1, 'Order is created');

    ok($escrow->account->balance == 50, 'Money is deposited to Escrow account for first order');
    ok($agent->account->balance == 50,  'Money is withdrawn from Agent account for first order');

    is($order_data1->{status}, 'pending', 'Status for new order is correct');
    ok($order_data1->{amount} == 50, 'Amount for new order is correct');
    is($order_data1->{order_description}, $order_description, 'Description for new order is correct');

    my $order_data2 = $client2->p2p_order_create(
        offer_id          => $offer->{offer_id},
        amount            => 50,
        expiry            => 7200,
        order_description => $order_description
    );

    ok($order_data2, 'Order is created');

    ok($escrow->account->balance == 100, 'Money is deposited to Escrow account for second order');
    ok($agent->account->balance == 0,    'Money is withdrawn from Agent account for second order');

    is($order_data2->{status}, 'pending', 'Status for new order is correct');
    ok($order_data2->{amount} == 50, 'Amount for new order is correct');
    is($order_data2->{order_description}, $order_description, 'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating two orders from one client for two offers' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent1, $offer1) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my ($agent2, $offer2) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,       'Escrow balance is correct');
    ok($agent1->account->balance == $amount, 'Agent balance is correct');
    ok($agent2->account->balance == $amount, 'Agent balance is correct');

    my $order_data1 = $client->p2p_order_create(
        offer_id          => $offer1->{offer_id},
        amount            => 100,
        expiry            => 7200,
        order_description => $order_description
    );

    ok($order_data1, 'Order is created');

    ok($escrow->account->balance == 100, 'Money is deposited to Escrow account for first order');
    ok($agent1->account->balance == 0,   'Money is withdrawn from Agent account for first order');

    is($order_data1->{status}, 'pending', 'Status for new order is correct');
    ok($order_data1->{amount} == 100, 'Amount for new order is correct');
    is($order_data1->{order_description}, $order_description, 'Description for new order is correct');

    my $order_data2 = $client->p2p_order_create(
        offer_id          => $offer2->{offer_id},
        amount            => 100,
        expiry            => 7200,
        order_description => $order_description
    );

    ok($order_data2, 'Order is created');

    ok($escrow->account->balance == 200, 'Money is deposited to Escrow account for second order');
    ok($agent2->account->balance == 0,   'Money is withdrawn from Agent account for second order');

    is($order_data2->{status}, 'pending', 'Status for new order is correct');
    ok($order_data2->{amount} == 100, 'Amount for new order is correct');
    is($order_data2->{order_description}, $order_description, 'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating two new orders from one client for one offer' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();

    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $order_data = $client->p2p_order_create(
        offer_id          => $offer->{offer_id},
        amount            => 50,
        expiry            => 7200,
        order_description => $order_description
    );

    ok($order_data, 'Order is created');

    ok($escrow->account->balance == 50, 'Money is deposited to Escrow account for first order');
    ok($agent->account->balance == 50,  'Money is withdrawn from Agent account for first order');

    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{amount} == 50, 'Amount for new order is correct');
    is($order_data->{order_description}, $order_description, 'Description for new order is correct');

    my $err = exception {
        $client->p2p_order_create(
            offer_id          => $offer->{offer_id},
            amount            => 50,
            expiry            => 7200,
            order_description => $order_description
        );
    };
    chomp $err;
    is $err, 'OrderAlreadyExists', 'Got correct error';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order for agent own order' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $agent->p2p_order_create(
            offer_id          => $offer->{offer_id},
            amount            => 100,
            expiry            => 7200,
            order_description => $order_description
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
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $client->p2p_order_create(
            offer_id          => $offer->{offer_id},
            amount            => 101,
            expiry            => 7200,
            order_description => $order_description
        );
    };

    is $err->{error_code}, 'OrderMaximumExceeded', 'Got correct error code';

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order with negative amount' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $client->p2p_order_create(
            offer_id          => $offer->{offer_id},
            amount            => -1,
            expiry            => 7200,
            order_description => $order_description
        );
    };

    is $err->{error_code}, 'OrderMinimumNotMet', 'Got correct error code';

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order outside min-max range' => sub {
    my $amount     = 100;
    my $min_amount = 20;
    my $max_amount = 50;

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
            offer_id          => $offer->{offer_id},
            amount            => $min_amount - 1,
            expiry            => 7200,
            order_description => $order_description
        );
    };

    is $err->{error_code}, 'OrderMinimumNotMet', 'Got correct error code';
    cmp_bag($err->{message_params}, [$account_currency, formatnumber('amount', $account_currency, $min_amount)], 'Got correct error values');

    $err = exception {
        $client->p2p_order_create(
            offer_id          => $offer->{offer_id},
            amount            => $max_amount + 1,
            expiry            => 7200,
            order_description => $order_description
        );
    };

    is $err->{error_code}, 'OrderMaximumExceeded', 'Got correct error code';
    cmp_bag($err->{message_params}, [$account_currency, formatnumber('amount', $account_currency, $max_amount)], 'Got correct error values');

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order with disabled agent' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    $agent->p2p_agent_update(is_active => 0);

    my $err = exception {
        $client->p2p_order_create(
            offer_id          => $offer->{offer_id},
            amount            => $amount,
            expiry            => 7200,
            order_description => $order_description
        );
    };

    chomp($err);
    is $err, 'AgentNotActive', 'Got correct error code';

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order without escrow' => sub {
    my $amount = 100;

    my $original_escrow = BOM::Config::Runtime->instance->app_config->payments->p2p->escrow;
    BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([]);

    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $client->p2p_order_create(
            offer_id          => $offer->{offer_id},
            amount            => $amount,
            expiry            => 7200,
            order_description => $order_description
        );
    };

    chomp($err);
    is $err, 'EscrowNotFound', 'Got correct error code';

    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Config::Runtime->instance->app_config->payments->p2p->escrow($original_escrow);
};

subtest 'Creating order with wrong currency' => sub {
    my $amount      = 100;
    my $description = 'Test order';

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(amount => $amount);

    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('EUR');

    my $err = exception {
        $client->p2p_order_create(
            offer_id    => $offer->{offer_id},
            amount      => $amount,
            expiry      => 7200,
            description => $description
        );
    };

    chomp($err);
    is $err, 'InvalidOrderCurrency', 'Got correct error code';

    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Sell offers' => sub {
    my $amount = 100;

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
        offer_id          => $offer->{offer_id},
        amount            => 100,
        expiry            => 7200,
        order_description => $order_description
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
    ok($order_data->{amount} == $amount, 'Amount for new order is correct');
    is($order_data->{order_description}, $order_description, 'Description for new order is correct');
    is($order_data->{type},        'sell',             'offer type is sell');

    BOM::Test::Helper::P2P::reset_escrow();

};

done_testing();
