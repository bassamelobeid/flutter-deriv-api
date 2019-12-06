use strict;
use warnings;

use Test::More;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::OTC;
use BOM::Config::Runtime;
use Test::Fatal;
use Data::Dumper;

subtest 'Creating new order' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::OTC::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::OTC::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $order_data = $client->create_otc_order(
        offer_id    => $offer->{id},
        amount      => 100,
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

    BOM::Test::Helper::OTC::reset_escrow();
};

subtest 'Creating two orders from two clients' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::OTC::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => $amount);
    my $client1 = BOM::Test::Helper::OTC::create_client();
    my $client2 = BOM::Test::Helper::OTC::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $order_data1 = $client1->create_otc_order(
        offer_id    => $offer->{id},
        amount      => 50,
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

    my $order_data2 = $client2->create_otc_order(
        offer_id    => $offer->{id},
        amount      => 50,
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

    BOM::Test::Helper::OTC::reset_escrow();
};

subtest 'Creating two orders from one client for two offers' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::OTC::create_escrow();
    my ($agent1, $offer1) = BOM::Test::Helper::OTC::create_offer(amount => $amount);
    my ($agent2, $offer2) = BOM::Test::Helper::OTC::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::OTC::create_client();

    ok($escrow->account->balance == 0,       'Escrow balance is correct');
    ok($agent1->account->balance == $amount, 'Agent balance is correct');
    ok($agent2->account->balance == $amount, 'Agent balance is correct');

    my $order_data1 = $client->create_otc_order(
        offer_id    => $offer1->{id},
        amount      => 100,
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

    my $order_data2 = $client->create_otc_order(
        offer_id    => $offer2->{id},
        amount      => 100,
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

    BOM::Test::Helper::OTC::reset_escrow();
};

subtest 'Creating two new orders from one client for one offer' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::OTC::create_escrow();

    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::OTC::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $order_data = $client->create_otc_order(
        offer_id    => $offer->{id},
        amount      => 50,
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
        $client->create_otc_order(
            offer_id    => $offer->{id},
            amount      => 50,
            description => $description
        );
    };
    chomp $err;
    is $err, 'OrderAlreadyExists', 'Got correct error';

    BOM::Test::Helper::OTC::reset_escrow();
};

subtest 'Creating order for agent own order' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::OTC::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => $amount);

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $agent->create_otc_order(
            offer_id    => $offer->{id},
            amount      => 100,
            description => $description
        );
    };
    chomp($err);
    note explain $err;
    is $err, 'InvalidOfferOwn', 'Got correct error code';

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::OTC::reset_escrow();
};

subtest 'Creating order with amount more than avalible' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::OTC::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::OTC::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $client->create_otc_order(
            offer_id    => $offer->{id},
            amount      => 101,
            description => $description
        );
    };

    chomp($err);
    is $err, 'InvalidAmount', 'Got correct error code';

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::OTC::reset_escrow();
};

subtest 'Creating order with negative amount' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::OTC::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::OTC::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $client->create_otc_order(
            offer_id    => $offer->{id},
            amount      => -1,
            description => $description
        );
    };

    chomp($err);
    is $err, 'InvalidAmount', 'Got correct error code';

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::OTC::reset_escrow();
};

subtest 'Creating order with disabled agent' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my $escrow = BOM::Test::Helper::OTC::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::OTC::create_client();

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    $agent->update_otc_agent(active => 0);

    my $err = exception {
        $client->create_otc_order(
            offer_id    => $offer->{id},
            amount      => $amount,
            description => $description
        );
    };

    chomp($err);
    is $err, 'OfferOwnerNotAuthenticated', 'Got correct error code';

    ok($escrow->account->balance == 0,      'Escrow balance is correct');
    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::OTC::reset_escrow();
};

subtest 'Creating order without escrow' => sub {
    my $amount      = 100;
    my $description = 'Test order';
    my $source      = 1;

    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::OTC::create_client();

    ok($agent->account->balance == $amount, 'Agent balance is correct');

    my $err = exception {
        $client->create_otc_order(
            offer_id    => $offer->{id},
            amount      => $amount,
            description => $description
        );
    };

    chomp($err);
    is $err, 'EscrowNotFound', 'Got correct error code';

    ok($agent->account->balance == $amount, 'Agent balance is correct');

    BOM::Test::Helper::OTC::reset_escrow();
};

subtest 'Creating order for expired offer' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::OTC::create_escrow();
    my ($agent, $offer) = BOM::Test::Helper::OTC::create_offer(amount => $amount);
    my $client = BOM::Test::Helper::OTC::create_client();

    BOM::Test::Helper::OTC::expire_offer($agent, $offer->{id});

    my $err = exception {
        $client->create_otc_order(
            offer_id => $offer->{id},
            amount   => $amount
        );
    };

    chomp($err);
    is $err, 'InvalidOfferExpired', 'Got correct error code';
};

done_testing();
