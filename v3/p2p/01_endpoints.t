use strict;
use warnings;
use Test::More;
use Test::Deep;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test test_schema/;
use await;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw(top_up);
use BOM::Test::Helper::Token qw(cleanup_redis_tokens);
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;

cleanup_redis_tokens();

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

$app_config->set({'payments.p2p.enabled'   => 1});
$app_config->set({'system.suspend.p2p'     => 0});
$app_config->set({'payments.p2p.available' => 1});

my $t = build_wsapi_test();

my $email_agent  = 'p2p_agent@test.com';
my $email_client = 'p2p_client@test.com';

my $cl_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email_agent
});

my $cl_agent = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email_agent
});

my $user_agent = BOM::User->create(
    email    => $email_agent,
    password => 'test'
);
$user_agent->add_client($cl_vr);
$user_agent->add_client($cl_agent);
$cl_agent->account('USD');
top_up($cl_agent, $cl_agent->currency, 1000);

my $cl_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email_client
});

my $user_client = BOM::User->create(
    email    => $email_client,
    password => 'test'
);
$user_client->add_client($cl_client);
$cl_client->account('USD');

my $cl_escrow = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'p2p_escrow@test.com'
});
$cl_escrow->account('USD');
$app_config->set({'payments.p2p.escrow' => [$cl_escrow->loginid]});

my %offer_params = (
    amount            => 100,
    offer_description => 'Test offer',
    method            => 'bank_transfer',
    type              => 'buy',
    local_currency    => 'IDR',
    rate              => 1,
    min_amount        => 0.1,
    max_amount        => 10,
);

my ($resp, $tok_vr, $tok_agent, $tok_client, $agent, $offer, $order);
my $agent_name = 'agent' . rand(999);

subtest 'misc' => sub {
    $tok_vr = BOM::Platform::Token::API->new->create_token($cl_vr->loginid, 'test token');
    $t->await::authorize({authorize => $tok_vr});
    $resp = $t->await::p2p_offer_list({p2p_offer_list => 1})->{error};
    ok $resp->{code} eq 'PermissionDenied' && $resp->{message} =~ /requires payments scope/, 'Payments scope required';

    $tok_vr = BOM::Platform::Token::API->new->create_token($cl_vr->loginid, 'test token', ['payments']);
    $t->await::authorize({authorize => $tok_vr});
    $resp = $t->await::p2p_offer_list({p2p_offer_list => 1})->{error};
    is $resp->{code}, 'UnavailableOnVirtual', 'VR not allowed';

    $tok_client = BOM::Platform::Token::API->new->create_token($cl_client->loginid, 'test token', ['payments']);
    $t->await::authorize({authorize => $tok_client});
    $resp = $t->await::p2p_offer_list({p2p_offer_list => 1})->{p2p_offer_list}{list};
    ok ref $resp eq 'ARRAY' && $resp->@* == 0, 'Client gets empty offer list';
};

subtest 'create agent' => sub {
    $tok_agent = BOM::Platform::Token::API->new->create_token($cl_agent->loginid, 'test token', ['payments']);
    $t->await::authorize({authorize => $tok_agent});
    $resp = $t->await::p2p_agent_info({p2p_agent_info => 1})->{error};
    is $resp->{code}, 'AgentNotFound', 'Agent not yet registered';

    $cl_agent->p2p_agent_create($agent_name);
    $resp = $t->await::p2p_agent_info({p2p_agent_info => 1});
    test_schema('p2p_agent_info', $resp);

    $agent = $resp->{p2p_agent_info};
    is $agent->{agent_name}, $agent_name, 'agent name';
    ok $agent->{agent_id} > 0, 'agent id';
    ok !$agent->{is_approved}, 'agent not approved';
    ok $agent->{is_active}, 'agent active';

    $resp = $t->await::p2p_offer_create({
            p2p_offer_create => 1,
            %offer_params
        })->{error};
    is $resp->{code}, 'AgentNotApproved', 'Unapproved agent';
};

subtest 'update agent' => sub {
    $tok_agent = BOM::Platform::Token::API->new->create_token($cl_agent->loginid, 'test token', ['payments']);
    $t->await::authorize({authorize => $tok_agent});

    my $new_agent_name = 'new agent name';

    $resp = $t->await::p2p_agent_update({
            p2p_agent_update => 1,
            agent_name       => $new_agent_name,
        })->{error};
    is $resp->{code}, 'AgentNotApproved', 'Unapproved agent cannot update the information';

    $cl_agent->p2p_agent_update(is_approved => 1);

    $resp = $t->await::p2p_agent_update({
            p2p_agent_update => 1,
            agent_name       => ' ',
        })->{error};
    ok $resp->{code} eq 'InputValidationFailed' && $resp->{message} =~ /agent_name/, 'Agent name cannot be blank';

    $agent = $t->await::p2p_agent_update({
            p2p_agent_update => 1,
            agent_name       => $new_agent_name,
            is_active        => 0,
        })->{p2p_agent_update};
    is $agent->{agent_name}, $new_agent_name, 'update agent name';
    ok !$agent->{is_active}, 'set agent inactive';

    $resp = $t->await::p2p_agent_update({
        p2p_agent_update => 1,
        agent_name       => $agent_name,
        is_active        => 1,
    });
    test_schema('p2p_agent_update', $resp);
    $agent = $resp->{p2p_agent_update};
    is $agent->{agent_name}, $agent_name, 'update agent name';
    ok $agent->{is_active}, 'set agent active';
};

subtest 'create offer' => sub {
    $cl_agent->p2p_agent_update(is_approved => 1);
    $resp = $t->await::p2p_offer_create({
        p2p_offer_create => 1,
        %offer_params
    });
    test_schema('p2p_offer_create', $resp);
    $offer = $resp->{p2p_offer_create};

    is $offer->{account_currency}, $cl_agent->account->currency_code, 'account currency';
    is $offer->{agent_id}, $agent->{agent_id}, 'agent id';
    ok $offer->{amount} == $offer_params{amount} && $offer->{amount_display} == $offer_params{amount}, 'amount';
    ok $offer->{remaining_amount} == $offer_params{amount} && $offer->{remaining_amount_display} == $offer_params{amount}, 'remaining';
    is $offer->{country}, $cl_agent->residence, 'country';
    ok $offer->{is_active}, 'is active';
    is $offer->{local_currency}, $offer_params{local_currency}, 'local currency';
    ok $offer->{max_amount} == $offer_params{max_amount} && $offer->{max_amount_display} == $offer_params{max_amount}, 'max amount';
    is $offer->{offer_description}, $offer_params{offer_description}, 'description';
    ok $offer->{offer_id} > 0, 'offer id';
    ok $offer->{price} == $offer_params{rate} && $offer->{price_display} == $offer_params{rate}, 'price';
    ok $offer->{rate} == $offer_params{rate}  && $offer->{rate_display} == $offer_params{rate},  'rate';
    is $offer->{type}, $offer_params{type}, 'type';

    $resp = $t->await::p2p_offer_list({p2p_offer_list => 1});
    test_schema('p2p_offer_list', $resp);
    cmp_deeply($resp->{p2p_offer_list}{list}[0], $offer, 'Offer list item matches offer create');

    $resp = $t->await::p2p_offer_info({
            p2p_offer_info => 1,
            offer_id       => $offer->{offer_id}});
    test_schema('p2p_offer_info', $resp);
    cmp_deeply($resp->{p2p_offer_info}, $offer, 'Offer info matches offer create');
    
    $resp = $t->await::p2p_agent_offers({p2p_agent_offers => 1});
    test_schema('p2p_agent_offers', $resp);
    cmp_deeply($resp->{p2p_agent_offers}{list}[0], $offer, 'Agent offers item matches offer create');
};

subtest 'create order' => sub {
    my $amount = 10;
    my $price  = $offer->{price} * $amount;

    $t->await::authorize({authorize => $tok_client});

    $resp = $t->await::p2p_order_create({
        p2p_order_create => 1,
        offer_id         => $offer->{offer_id},
        amount           => $amount
    });
    test_schema('p2p_order_create', $resp);
    $order = $resp->{p2p_order_create};

    is $order->{account_currency}, $cl_agent->account->currency_code, 'account currency';
    is $order->{agent_id}, $agent->{agent_id}, 'agent id';
    is $order->{agent_name}, $agent_name, 'agent name';
    ok $order->{amount} == $amount && $order->{amount_display} == $amount, 'amount';
    ok $order->{expiry_time},    'expiry time';
    is $order->{local_currency}, $offer_params{local_currency}, 'local currency';
    is $order->{offer_id},       $offer->{offer_id}, 'offer id';
    ok $order->{price} == $price && $order->{price_display} == $price, 'price';
    ok $order->{rate} == $offer->{rate} && $order->{rate_display} == $offer->{rate_display}, 'rate';
    is $order->{status}, 'pending', 'status';
    is $order->{type}, $offer->{type}, 'type';

    $resp = $t->await::p2p_order_list({p2p_order_list => 1});
    test_schema('p2p_order_list', $resp);
    my $listed_order = $resp->{p2p_order_list}{list}[0];

    $resp = $t->await::p2p_order_info({
            p2p_order_info => 1,
            order_id       => $order->{order_id}});
    test_schema('p2p_order_info', $resp);
    my $order_info = $resp->{p2p_order_info};

    cmp_deeply($order_info,   $listed_order, 'Order info matches order list');
    cmp_deeply($listed_order, $order,        'Order list matches order create');
};

subtest 'confirm order' => sub {
    $t->await::authorize({authorize => $tok_client});
    $resp = $t->await::p2p_order_confirm({
            p2p_order_confirm => 1,
            order_id          => $order->{order_id}});
    test_schema('p2p_order_confirm', $resp);
    is $resp->{p2p_order_confirm}{order_id}, $order->{order_id}, 'client confirm: order id';
    is $resp->{p2p_order_confirm}{status}, 'buyer-confirmed', 'client confirm: status';

    $t->await::authorize({authorize => $tok_agent});
    $resp = $t->await::p2p_order_confirm({
            p2p_order_confirm => 1,
            order_id          => $order->{order_id}});
    test_schema('p2p_order_confirm', $resp);
    is $resp->{p2p_order_confirm}{order_id}, $order->{order_id}, 'agent_confirm: order id';
    is $resp->{p2p_order_confirm}{status}, 'completed', 'agent_confirm: status';
};

subtest 'cancel order' => sub {
    $t->await::authorize({authorize => $tok_client});
    $order = $t->await::p2p_order_create({
            p2p_order_create => 1,
            offer_id         => $offer->{offer_id},
            amount           => 10
        })->{p2p_order_create};
    $resp = $t->await::p2p_order_cancel({
            p2p_order_cancel => 1,
            order_id         => $order->{order_id}});
    test_schema('p2p_order_cancel', $resp);
    is $resp->{p2p_order_cancel}{order_id}, $order->{order_id}, 'order id';
    is $resp->{p2p_order_cancel}{status}, 'cancelled', 'status';
};

$t->finish_ok;

done_testing();
