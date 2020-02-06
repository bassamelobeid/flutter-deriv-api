use strict;
use warnings;
use BOM::Test::RPC::Client;
use Test::More;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Token qw(cleanup_redis_tokens);
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::RPC::v3::P2P;
use BOM::Test::Helper::P2P;

cleanup_redis_tokens();

#Test endpoint for testing logic in function p2p_rpc
my $dummy_method = 'test_p2p_controller';
BOM::RPC::v3::P2P::p2p_rpc $dummy_method => sub { return {success => 1} };

my $app_config = BOM::Config::Runtime->instance->app_config;
my ($p2p_suspend, $p2p_enable) = ($app_config->system->suspend->p2p, $app_config->payments->p2p->enabled);
$app_config->system->suspend->p2p(0);
$app_config->payments->p2p->enabled(1);
$app_config->payments->p2p->available(1);

my $email_agent  = 'p2p_agent@test.com';
my $email_client = 'p2p_client@test.com';

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email_agent
});

my $client_agent = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email_agent
});

my $user_agent = BOM::User->create(
    email    => $email_agent,
    password => 'test'
);
$user_agent->add_client($client_vr);
$user_agent->add_client($client_agent);

my $client_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email_client
});

my $user_client = BOM::User->create(
    email    => $email_client,
    password => 'test'
);
$user_client->add_client($client_client);

my $token_vr     = BOM::Platform::Token::API->new->create_token($client_vr->loginid,     'test vr token');
my $token_agent  = BOM::Platform::Token::API->new->create_token($client_agent->loginid,  'test agent token');
my $token_client = BOM::Platform::Token::API->new->create_token($client_client->loginid, 'test client token');

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

my $params = {language => 'EN'};
my $offer;

subtest 'No token' => sub {
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'error code is InvalidToken');
};

subtest 'VR not allowed' => sub {
    $params->{token} = $token_vr;
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_error->error_code_is('UnavailableOnVirtual', 'error code is UnavailableOnVirtual');
};

subtest 'P2P suspended' => sub {
    $app_config->system->suspend->p2p(1);
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_error->error_code_is('P2PDisabled', 'error code is P2PDisabled');
    $app_config->system->suspend->p2p(0);
};

subtest 'P2P payments disabled' => sub {
    $app_config->payments->p2p->enabled(0);
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_error->error_code_is('P2PDisabled', 'error code is P2PDisabled');
    $app_config->payments->p2p->enabled(1);
};

subtest 'No account' => sub {
    $params->{token} = $token_agent;
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_error->error_code_is('NoCurrency', 'error code is NoCurrency');
};

subtest 'Client restricted statuses' => sub {
    $client_agent->set_default_account('USD');

    my @restricted_statuses = qw(
        unwelcome
        cashier_locked
        withdrawal_locked
        no_withdrawal_or_trading
    );

    for my $status (@restricted_statuses) {
        $client_agent->status->set($status);
        $c->call_ok($dummy_method, $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied', "error code is PermissionDenied for status $status");
        my $clear_status = "clear_$status";
        $client_agent->status->$clear_status;
    }

    $c->call_ok($dummy_method, $params)->has_no_system_error->has_no_error('No errors with valid client & args');
};

$app_config->payments->p2p->available(0);
subtest 'P2P is not available to anyone' => sub {
    $c->call_ok($dummy_method, $params)
        ->has_no_system_error->has_error->error_code_is('PermissionDenied',
        "error code is PermissionDenied, because payments.p2p.available is unchecked");
};

subtest 'P2P is available for only one client' => sub {
    $app_config->payments->p2p->clients([$client_agent->loginid]);
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_no_error("P2P is available for whitelisted client");
};
$app_config->payments->p2p->available(1);

subtest 'Offers' => sub {
    my $offer_params = {
        amount            => 100,
        offer_description => 'Test offer',
        type              => 'buy',
        account_currency  => 'USD',
        expiry            => 30,
        rate              => 1.23,
        min_amount        => 0.1,
        max_amount        => 10,
        method            => 'test method',
    };

    $params->{args} = {agent_name => 'Bond007'};

    $c->call_ok('p2p_agent_update', $params)->has_no_system_error->has_error->error_code_is('AgentNotRegistered', 'Update non-existent agent');

    my $res = $c->call_ok('p2p_agent_create', $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'pending', 'result has p2p agent status = pending';

    $params->{args} = {agent_name => 'SpyvsSpy'};
    $c->call_ok('p2p_agent_update', $params)
        ->has_no_system_error->has_error->error_code_is('AgentNotApproved',
        'Cannot update the agent information when agent is not approved');

    $client_agent->p2p_agent_update(is_approved => 1);
    $res = $c->call_ok('p2p_agent_update', $params)->has_no_system_error->has_no_error->result;
    is $res->{agent_name}, $params->{args}{agent_name}, 'update agent name';

    $params->{args} = {agent_name => ' '};
    $c->call_ok('p2p_agent_update', $params)
        ->has_no_system_error->has_error->error_code_is('AgentNameRequired', 'Cannot update the agent name to blank');

    $client_agent->p2p_agent_update(is_approved => 0);
    $params->{args} = $offer_params;
    $c->call_ok('p2p_offer_create', $params)
        ->has_no_system_error->has_error->error_code_is('AgentNotApproved', "unapproved agent, create offer error is AgentNotApproved");

    $client_agent->p2p_agent_update(
        is_approved => 1,
        is_active        => 0
    );

    $params->{args} = $offer_params;
    $c->call_ok('p2p_offer_create', $params)
        ->has_no_system_error->has_error->error_code_is('AgentNotActive', "inactive agent, create offer error is AgentNotActive");

    $client_agent->p2p_agent_update(is_active => 1);

    $params->{args} = {agent => $client_agent->p2p_agent_info->{agent_id}};
    $res = $c->call_ok('p2p_agent_info', $params)->has_no_system_error->has_no_error->result;
    ok $res->{is_approved} && $res->{is_active}, 'p2p_agent_info returns agent is approved and active';

    $params->{args} = {agent_id => 9999};
    $c->call_ok('p2p_agent_info', $params)->has_no_system_error->has_error->error_code_is('AgentNotFound', 'Get info of non-existent agent');

    for my $numeric_field (qw(amount max_amount min_amount rate)) {
        $params->{args} = {$offer_params->%*};

        for (-1, 0) {
            $params->{args}{$numeric_field} = $_;
            $c->call_ok('p2p_offer_create', $params)
                ->has_no_system_error->has_error->error_code_is('InvalidNumericValue', "Value of '$numeric_field' should be greater than 0")
                ->error_details_is({fields => [$numeric_field]}, 'Error details is correct.');
        }
    }

    $params->{args} = {$offer_params->%*};
    $params->{args}{min_amount} = $params->{args}{max_amount} + 1;
    $c->call_ok('p2p_offer_create', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidMinMaxAmount', 'min_amount cannot be greater than max_amount');

    $params->{args}             = {$offer_params->%*};
    $params->{args}{amount}     = 80;
    $params->{args}{max_amount} = $params->{args}{amount} + 1;
    $c->call_ok('p2p_offer_create', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidMaxAmount', 'Offer amount cannot be less than max_amount');

    $params->{args} = {$offer_params->%*};
    $params->{args}{max_amount} = $app_config->payments->p2p->limits->maximum_order + 1;
    $c->call_ok('p2p_offer_create', $params)
        ->has_no_system_error->has_error->error_code_is('MaxPerOrderExceeded', 'Offer max_amount cannot be more than maximum_order amount config');

    $params->{args} = $offer_params;
    $offer = $c->call_ok('p2p_offer_create', $params)->has_no_system_error->has_no_error->result;
    delete $offer->{stash};
    ok $offer->{offer_id}, 'offer has id';

    $params->{args} = {};
    $res = $c->call_ok('p2p_offer_list', $params)->has_no_system_error->has_no_error->result->{list};
    cmp_ok $res->[0]->{offer_id}, '==', $offer->{offer_id}, 'p2p_offer_list returns offer';

    $params->{args} = {
        offer_id          => $offer->{offer_id},
        offer_description => 'new description'
    };
    $res = $c->call_ok('p2p_offer_update', $params)->has_no_system_error->has_no_error->result;
    is $res->{offer_description}, 'new description', 'edit offer ok';

    $params->{args} = {offer_id => $offer->{offer_id}};
    $res = $c->call_ok('p2p_offer_info', $params)->has_no_system_error->has_no_error->result;
    cmp_ok $res->{offer_id}, '==', $offer->{offer_id}, 'p2p_offer_info returned correct info';

    $params->{args} = {offer_id => 9999};
    $c->call_ok('p2p_offer_info',   $params)->has_no_system_error->has_error->error_code_is('OfferNotFound', 'Get info for non-existent offer');
    $c->call_ok('p2p_offer_update', $params)->has_no_system_error->has_error->error_code_is('OfferNotFound', 'Edit non-existent offer');
    
    $res = $c->call_ok('p2p_agent_offers', $params)->has_no_system_error->has_no_error->result;
    is $res->{list}[0]{offer_id}, $offer->{offer_id}, 'Offer returned in p2p_agent_offers';
};

subtest 'Create new order' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer();
    my $client = BOM::Test::Helper::P2P::create_client();
    my $params;
    $client->set_default_account('USD');
    $params->{token} = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    $agent->payment_free_gift(
        currency => 'USD',
        amount   => 100,
        remark   => 'free gift'
    );

    $params->{args} = {
        offer_id          => $offer->{offer_id},
        amount            => 100,
        order_description => 'here is my order'
    };

    my $order = $c->call_ok('p2p_order_create', $params)->has_no_system_error->has_no_error->result;
    ok($order->{order_id},         'Order is created');
    ok($order->{account_currency}, 'Order has account_currency');
    ok($order->{local_currency},   'Order has local_currency');
    is($order->{order_description}, $params->{args}{order_description}, 'Order description is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Client confirm an order' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer();
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(offer_id => $offer->{offer_id});

    $params->{token} = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    $params->{args} = {order_id => $order->{order_id}};

    my $res = $c->call_ok(p2p_order_confirm => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'buyer-confirmed', 'Order is confirmed';

    $params->{args} = {order_id => 9999};
    $c->call_ok('p2p_order_confirm', $params)->has_no_system_error->has_error->error_code_is('OrderNotFound', 'Confirm non-existent order');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Agent confirm' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer();
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(offer_id => $offer->{offer_id});

    my $client_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    my $agent_token  = BOM::Platform::Token::API->new->create_token($agent->loginid,  'test token');

    $params->{token} = $client_token;
    $params->{args} = {order_id => $order->{order_id}};

    my $res = $c->call_ok(p2p_order_confirm => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'buyer-confirmed', 'Order is buyer confirmed';

    $params->{token} = $agent_token;
    $params->{args} = {order_id => $order->{order_id}};

    $res = $c->call_ok(p2p_order_confirm => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'completed', 'Order is completed';
    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Client cancellation' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer();
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(offer_id => $offer->{offer_id});

    my $client_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    my $agent_token  = BOM::Platform::Token::API->new->create_token($agent->loginid,  'test token');

    $params->{token} = $client_token;
    $params->{args} = {order_id => $order->{order_id}};

    my $res = $c->call_ok(p2p_order_cancel => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'cancelled', 'Order is cancelled';

    $params->{args} = {order_id => 9999};
    $c->call_ok('p2p_order_cancel', $params)->has_no_system_error->has_error->error_code_is('OrderNotFound', 'Cancel non-existent order');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Getting order list' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($agent,  $offer) = BOM::Test::Helper::P2P::create_offer();
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        offer_id => $offer->{offer_id},
        amount   => 10
    );

    my $client_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    my $agent_token  = BOM::Platform::Token::API->new->create_token($agent->loginid,  'test token');

    $params->{token} = $agent_token;
    $params->{args} = {offer_id => $offer->{offer_id}};

    my $res1 = $c->call_ok(p2p_order_list => $params)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res1->{list}}), '==', 1, 'count of offers is correct';

    my ($client2, $order2) = BOM::Test::Helper::P2P::create_order(
        offer_id => $offer->{offer_id},
        amount   => 10
    );

    my $res2 = $c->call_ok(p2p_order_list => $params)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res2->{list}}), '==', 2, 'count of orders is correct';

    $params->{token} = $client_token;
    $params->{args} = {offer_id => $offer->{offer_id}};

    my $res3 = $c->call_ok(p2p_order_list => $params)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res3->{list}}), '==', 1, 'count of orders is correct';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Order list pagination' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer();

    BOM::Test::Helper::P2P::create_order(
        offer_id => $offer->{offer_id},
        amount   => 10
    ) for (1 .. 2);

    my $param = {};
    $param->{token} = BOM::Platform::Token::API->new->create_token($agent->loginid, 'test token');

    my $res1 = $c->call_ok(p2p_order_list => $param)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res1->{list}}), '==', 2, 'Got 2 orders in a list';

    my ($first_order, $second_order) = @{$res1->{list}};

    $param->{args} = {limit => 1};
    my $res2 = $c->call_ok(p2p_order_list => $param)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res2->{list}}), '==', 1, 'got 1 order with limit 1';
    cmp_ok $res2->{list}[0]{order_id}, 'eq', $first_order->{order_id}, 'got correct order id with limit 1';

    $param->{args} = {
        limit  => 1,
        offset => 1
    };
    my $res3 = $c->call_ok(p2p_order_list => $param)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res3->{list}}), '==', 1, 'got 1 order with limit 1 and offest 1';
    cmp_ok $res3->{list}[0]{order_id}, 'eq', $second_order->{order_id}, 'got correct order id with limit 1 and offset 1';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Getting order list' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($agent1, $offer1) = BOM::Test::Helper::P2P::create_offer();

    my $agent1_token = BOM::Platform::Token::API->new->create_token($agent1->loginid, 'test token');
    $params->{token} = $agent1_token;
    $params->{args} = {agent_id => $agent1->p2p_agent_info->{agent_id}};

    my $res1 = $c->call_ok(p2p_offer_list => $params)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res1->{list}}), '==', 1, 'count of offers is correct';

    my ($agent2, $offer2) = BOM::Test::Helper::P2P::create_offer();

    my $agent2_token = BOM::Platform::Token::API->new->create_token($agent2->loginid, 'test token');
    $params->{token} = $agent2_token;
    $params->{args} = {agent_id => $agent2->p2p_agent_info->{agent_id}};

    my $res2 = $c->call_ok(p2p_offer_list => $params)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res2->{list}}), '==', 1, 'count of offers is correct';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Sell orders' => sub {
    my $amount = 100;

    BOM::Test::Helper::P2P::create_escrow();

    my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(
        amount => $amount,
        type   => 'sell'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        offer_id => $offer->{offer_id},
        balance  => $amount
    );

    my $client_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    my $agent_token  = BOM::Platform::Token::API->new->create_token($agent->loginid,  'test token');

    $params->{token} = $agent_token;
    $params->{args} = {order_id => $order->{order_id}};

    my $res = $c->call_ok(p2p_order_confirm => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'buyer-confirmed', 'Order is buyer confirmed';

    $params->{token} = $client_token;
    $params->{args} = {order_id => $order->{order_id}};

    $res = $c->call_ok(p2p_order_confirm => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'completed', 'Order is completed';

    BOM::Test::Helper::P2P::reset_escrow();
};

# restore app config
$app_config->system->suspend->p2p($p2p_suspend);
$app_config->payments->p2p->enabled($p2p_enable);

done_testing();
