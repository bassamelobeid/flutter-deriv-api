use strict;
use warnings;
use Log::Any::Test;
use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Token qw(cleanup_redis_tokens);
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::RPC::v3::P2P;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::Client;

#Test endpoint for testing logic in function p2p_rpc
BEGIN {
    BOM::RPC::v3::P2P::p2p_rpc 'test_p2p_controller' => sub { return {success => 1} };
}

use BOM::Test::RPC::QueueClient;

cleanup_redis_tokens();

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::purge_redis();

my $dummy_method = 'test_p2p_controller';

my $app_config = BOM::Config::Runtime->instance->app_config;
my ($p2p_suspend, $p2p_enable) = ($app_config->system->suspend->p2p, $app_config->payments->p2p->enabled);

my $P2P_AVAILABLE_CURRENCIES = ['usd'];

$app_config->system->suspend->p2p(0);
$app_config->payments->p2p->enabled(1);
$app_config->payments->p2p->available(1);
$app_config->payments->p2p->available_for_countries([]);
$app_config->payments->p2p->available_for_currencies($P2P_AVAILABLE_CURRENCIES);

my $email_advertiser = 'p2p_advertiser@test.com';
my $email_client     = 'p2p_client@test.com';

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email_advertiser
});

my $client_advertiser = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email_advertiser,
    residence   => 'za'
});

my $user_advertiser = BOM::User->create(
    email    => $email_advertiser,
    password => 'test'
);
$user_advertiser->add_client($client_vr);
$user_advertiser->add_client($client_advertiser);

my $client_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email_client
});

my $user_client = BOM::User->create(
    email    => $email_client,
    password => 'test'
);
$user_client->add_client($client_client);

my $token_vr         = BOM::Platform::Token::API->new->create_token($client_vr->loginid,         'test vr token');
my $token_advertiser = BOM::Platform::Token::API->new->create_token($client_advertiser->loginid, 'test advertiser token');

my $c = BOM::Test::RPC::QueueClient->new();

my $params = {language => 'EN'};
my $advert;

subtest 'DB errors' => sub {
    my %error_map = %BOM::RPC::v3::P2P::ERROR_MAP;
    my %db_errors = %BOM::RPC::v3::P2P::DB_ERRORS;

    for my $err_code_db (sort keys %db_errors) {
        ok exists $error_map{$db_errors{$err_code_db}}, "DB error '$err_code_db' has a corresponding error message in %ERROR_MAP";
    }
};

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
    $params->{token} = $token_advertiser;
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_error->error_code_is('NoCurrency', 'error code is NoCurrency');
};

$client_advertiser->set_default_account('USD');

subtest 'Currency not enabled' => sub {
    $app_config->payments->p2p->available_for_currencies([]);

    $c->call_ok($dummy_method, $params)->has_no_system_error->has_error->error_code_is('RestrictedCurrency', 'error code is RestrictedCurrency')
        ->error_message_is('USD is not supported at the moment.');

    $app_config->payments->p2p->available_for_currencies($P2P_AVAILABLE_CURRENCIES);

    $c->call_ok($dummy_method, $params)->has_no_system_error->has_no_error('No errors when the currency is allowed');
};

# client residence is za
subtest 'Available countries' => sub {
    $app_config->payments->p2p->available_for_countries(['ag', 'us']);
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_error('Access denied when residence not in list')
        ->error_code_is('RestrictedCountry', 'correct error code');

    $app_config->payments->p2p->available_for_countries(['ag', 'za']);
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_no_error('Access allowed when residence in list');

    $app_config->payments->p2p->available_for_countries([]);
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_no_error('Access allowed when setting is empty');
};

subtest 'Restricted countries' => sub {
    $app_config->payments->p2p->restricted_countries(['za']);
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_error('Access denied when residence in list')
        ->error_code_is('RestrictedCountry', 'correct error code');

    $app_config->payments->p2p->restricted_countries(['ag', 'us']);
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_no_error('Access allowed when residence not in list');

    $app_config->payments->p2p->restricted_countries([]);
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_no_error('Access allowed when setting is empty');
};

subtest 'Landing company does not allow p2p' => sub {
    my $mock_lc = Test::MockModule->new('LandingCompany');

    $mock_lc->mock('p2p_available' => sub { 0 });

    $c->call_ok($dummy_method, $params)->has_no_system_error->has_error->error_code_is('RestrictedCountry', 'error code is RestrictedCountry');
};

subtest 'Client restricted statuses' => sub {
    my @restricted_statuses = qw(
        unwelcome
        cashier_locked
        withdrawal_locked
        no_withdrawal_or_trading
    );

    for my $status (@restricted_statuses) {
        $client_advertiser->status->set($status);
        $c->call_ok($dummy_method, $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied', "error code is PermissionDenied for status $status");
        my $clear_status = "clear_$status";
        $client_advertiser->status->$clear_status;
    }

    $c->call_ok($dummy_method, $params)->has_no_system_error->has_no_error('No errors with valid client & args');
};

$app_config->payments->p2p->available(0);
subtest 'P2P is not available to anyone' => sub {
    $c->call_ok($dummy_method, $params)
        ->has_no_system_error->has_error->error_code_is('P2PDisabled', "error code is P2PDisabled, because payments.p2p.available is unchecked");
};

subtest 'P2P is available for only one client' => sub {
    $app_config->payments->p2p->clients([$client_advertiser->loginid]);
    $c->call_ok($dummy_method, $params)->has_no_system_error->has_no_error("P2P is available for whitelisted client");
};
$app_config->payments->p2p->available(1);

subtest 'Adverts' => sub {
    my $advert_params = {
        amount           => 100,
        description      => 'Test advert',
        type             => 'sell',
        account_currency => 'USD',
        expiry           => 30,
        rate             => 1.23,
        min_order_amount => 0.1,
        max_order_amount => 10,
        payment_method   => 'bank_transfer',
        payment_info     => 'Bank 123',
        contact_info     => 'Tel 123',
    };

    $params->{args} = {name => 'Bond007'};
    $c->call_ok('p2p_advertiser_update', $params)
        ->has_no_system_error->has_error->error_code_is('AdvertiserNotRegistered', 'Update non-existent advertiser');

    $params->{args} = {name => 'bond007'};

    my $res = $c->call_ok('p2p_advertiser_create', $params)->has_no_system_error->has_no_error->result;
    is $res->{name}, $params->{args}{name}, 'advertiser created';

    $params->{args} = {name => 'SpyvsSpy'};
    $c->call_ok('p2p_advertiser_update', $params)
        ->has_no_system_error->has_error->error_code_is('AdvertiserNotApproved',
        'Cannot update the advertiser information when advertiser is not approved');

    $client_advertiser->p2p_advertiser_update(is_approved => 1);
    $res = $c->call_ok('p2p_advertiser_update', $params)->has_no_system_error->has_no_error->result;
    is $res->{name}, $params->{args}{name}, 'update advertiser name';

    $params->{args} = {name => ' '};
    $c->call_ok('p2p_advertiser_update', $params)
        ->has_no_system_error->has_error->error_code_is('AdvertiserNameRequired', 'Cannot update the advertiser name to blank');

    $client_advertiser->p2p_advertiser_update(is_approved => 0);
    $params->{args} = $advert_params;
    $c->call_ok('p2p_advert_create', $params)
        ->has_no_system_error->has_error->error_code_is('AdvertiserNotApproved',
        "unapproved advertiser, create advert error is AdvertiserNotApproved");

    $client_advertiser->p2p_advertiser_update(
        is_approved => 1,
        is_listed   => 0,
    );

    my @offer_ids = ();    # store all agent's offer's ids to check p2p_agent_offers later
    $params->{args} = $advert_params;
    $res = $c->call_ok('p2p_advert_create', $params)->has_no_system_error->has_no_error('unlisted advertiser can still create advert')->result;
    push @offer_ids, $res->{offer_id};

    $client_advertiser->p2p_advertiser_update(is_listed => 1);

    $params->{args} = {advertiser => $client_advertiser->p2p_advertiser_info->{id}};
    $res = $c->call_ok('p2p_advertiser_info', $params)->has_no_system_error->has_no_error->result;
    ok $res->{is_approved} && $res->{is_listed}, 'p2p_advertiser_info returns advertiser is approved and the adverts are listed';

    $params->{args} = {id => 9999};
    $c->call_ok('p2p_advertiser_info', $params)
        ->has_no_system_error->has_error->error_code_is('AdvertiserNotFound', 'Get info of non-existent advertiser');

    for my $numeric_field (qw(amount max_order_amount min_order_amount rate)) {
        $params->{args} = {$advert_params->%*};

        for (-1, 0) {
            $params->{args}{$numeric_field} = $_;
            $c->call_ok('p2p_advert_create', $params)
                ->has_no_system_error->has_error->error_code_is('InvalidNumericValue', "Value of '$numeric_field' should be greater than 0")
                ->error_details_is({fields => [$numeric_field]}, 'Error details is correct.');
        }
    }

    $params->{args} = +{$advert_params->%*};
    $params->{args}{min_order_amount} = $params->{args}{max_order_amount} + 1;
    $c->call_ok('p2p_advert_create', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidMinMaxAmount', 'min_order_amount cannot be greater than max_order_amount');

    $params->{args}                   = {$advert_params->%*};
    $params->{args}{amount}           = 80;
    $params->{args}{max_order_amount} = $params->{args}{amount} + 1;
    $c->call_ok('p2p_advert_create', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidMaxAmount', 'Advert amount cannot be less than max_order_amount');

    $params->{args} = {$advert_params->%*};
    $params->{args}{max_order_amount} = $app_config->payments->p2p->limits->maximum_order + 1;
    $c->call_ok('p2p_advert_create', $params)
        ->has_no_system_error->has_error->error_code_is('MaxPerOrderExceeded',
        'Advert max_order_amount cannot be more than maximum_order amount config');

    $params->{args}                 = $advert_params;
    $params->{args}{local_currency} = 'AAA';
    $advert                         = $c->call_ok('p2p_advert_create', $params)->has_no_system_error->has_no_error->result;
    delete $advert->{stash};
    ok $advert->{id}, 'advert has id';
    push @offer_ids, $advert->{id};

    BOM::Test::Helper::Client::top_up($client_advertiser, $client_advertiser->currency, $advert_params->{amount});

    $params->{args} = {};
    $res = $c->call_ok('p2p_advert_list', $params)->has_no_system_error->has_no_error->result->{list};
    cmp_ok $res->[0]->{id}, '==', $advert->{id}, 'p2p_advert_list returns advert';

    $params->{args}                 = $advert_params;
    $params->{args}{local_currency} = 'BBB';
    $params->{args}{rate}           = 12.000001;
    $advert                         = $c->call_ok('p2p_advert_create', $params)->has_no_system_error->has_no_error->result;
    is $advert->{rate_display}, '12.000001', 'advert rate_display is correct';
    push @offer_ids, $advert->{id};

    $params->{args}{local_currency} = 'CCC';
    $params->{args}{rate}           = 1_000_000_000;
    $advert                         = $c->call_ok('p2p_advert_create', $params)->has_no_system_error->has_no_error->result;
    is $advert->{rate_display}, '1000000000.00', 'advert rate_display is correct for large numbers';
    push @offer_ids, $advert->{id};

    $params->{args}{rate} = 0.000001;
    delete $params->{args}{local_currency};
    $params->{args}{min_order_amount} = 11;
    $params->{args}{max_order_amount} = 20;
    $c->call_ok('p2p_advert_create', $params)->has_no_system_error->has_error->error_code_is('MinPriceTooSmall', 'Got error if min price is 0');

    $params->{args} = {
        id        => $advert->{id},
        is_active => 0,
    };
    $res = $c->call_ok('p2p_advert_update', $params)->has_no_system_error->has_no_error->result;
    is $res->{is_active}, 0, 'edit advert ok';
    $params->{args} = {
        id        => $advert->{id},
        is_active => 1,
    };
    $res = $c->call_ok('p2p_advert_update', $params)->has_no_system_error->has_no_error->result;
    is $res->{is_active}, 1, 'edit advert ok';

    $params->{args} = {id => $advert->{id}};
    $res = $c->call_ok('p2p_advert_info', $params)->has_no_system_error->has_no_error->result;
    cmp_ok $res->{id}, '==', $advert->{id}, 'p2p_advert_info returned correct info';

    $params->{args} = {id => 9999};
    $c->call_ok('p2p_advert_info',   $params)->has_no_system_error->has_error->error_code_is('AdvertNotFound', 'Get info for non-existent advert');
    $c->call_ok('p2p_advert_update', $params)->has_no_system_error->has_error->error_code_is('AdvertNotFound', 'Edit non-existent advert');

    $params->{args} = {};
    $res = $c->call_ok('p2p_advertiser_adverts', $params)->has_no_system_error->has_no_error->result;
    is((map { $_{offer_id} } $res->{list}->@*), @offer_ids, 'Advert returned in p2p_advertiser_adverts');
};

subtest 'Create new order' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my $client = BOM::Test::Helper::P2P::create_advertiser();
    my $params;
    $params->{token} = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    $advertiser->payment_free_gift(
        currency => 'USD',
        amount   => 100,
        remark   => 'free gift'
    );

    $params->{args} = {
        advert_id => $advert->{id},
        amount    => 100,
    };
    my $order = $c->call_ok('p2p_order_create', $params)->has_no_system_error->has_no_error->result;
    ok($order->{id},               'Order is created');
    ok($order->{account_currency}, 'Order has account_currency');
    ok($order->{local_currency},   'Order has local_currency');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Prevent create orders more than daily order limit number' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($params, $advertiser, $advert, $order);

    # Set maximum order create limit per day to 5
    $app_config->payments->p2p->limits->count_per_day_per_client(5);
    is($app_config->payments->p2p->limits->count_per_day_per_client, 5, 'Change `count_per_day_per_client` setting value to 5');

    # Create client
    my $client = BOM::Test::Helper::P2P::create_advertiser(balance => 100);

    for (my $i = 0; $i < $app_config->payments->p2p->limits->count_per_day_per_client - 1; $i++) {
        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert();
        BOM::Test::Helper::P2P::create_order(
            advert_id => $advert->{id},
            client    => $client,
            amount    => 10
        );
    }

    $params->{token} = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert();
    $params->{args} = {
        advert_id         => $advert->{id},
        amount            => 10,
        order_description => 'here is my order'
    };

    $order = $c->call_ok('p2p_order_create', $params)->has_no_system_error->has_no_error->result;

    ok($order->{id}, 'Orders will successfully created until numbers of created orders reached `count_per_day_per_client` limit.');

    ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert();
    $params->{args} = {
        advert_id         => $advert->{id},
        amount            => 10,
        order_description => 'here is my order'
    };

    # API v3 gives us an error when we are trying to submits order more than p2p.limits.count_per_day_per_client setting.
    $c->call_ok('p2p_order_create', $params)->has_no_system_error->has_error('Client daily order limit exceeded.')
        ->error_code_is('ClientDailyOrderLimitExceeded', 'Client daily order limit exceeded.')
        ->error_message_is('You may only place 5 orders every 24 hours. Please try again later.', 'Client max order is 5 per 24hours');

    # Increase count_per_day_per_client bye 1 to 6
    $app_config->payments->p2p->limits->count_per_day_per_client(6);
    is($app_config->payments->p2p->limits->count_per_day_per_client, 6, 'Change `count_per_day_per_client` setting value to 6');

    ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert();
    $params->{args} = {
        advert_id         => $advert->{id},
        amount            => 10,
        order_description => 'here is my order'
    };

    $order = $c->call_ok('p2p_order_create', $params)->has_no_system_error->has_no_error->result;

    ok($order->{id}, 'Orders will successfully created until numbers of created orders reached `count_per_day_per_client` limit.');

    ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert();
    $params->{args} = {
        advert_id         => $advert->{id},
        amount            => 10,
        order_description => 'here is my order'
    };

    # API v3 gives us an error when we are trying to submits order more than p2p.limits.count_per_day_per_client setting.
    $c->call_ok('p2p_order_create', $params)->has_no_system_error->has_error('Client daily order limit exceeded.')
        ->error_code_is('ClientDailyOrderLimitExceeded', 'Client daily order limit exceeded.')
        ->error_message_is('You may only place 6 orders every 24 hours. Please try again later.', 'Client max order is 6 per 24hours');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Client confirm an order' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});

    $params->{token} = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    $params->{args}  = {id => $order->{id}};
    my $res = $c->call_ok(p2p_order_confirm => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'buyer-confirmed', 'Order is confirmed';

    $params->{args} = {id => 9999};
    $c->call_ok('p2p_order_confirm', $params)->has_no_system_error->has_error->error_code_is('OrderNotFound', 'Confirm non-existent order');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Advertiser confirm' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});

    my $client_token     = BOM::Platform::Token::API->new->create_token($client->loginid,     'test token');
    my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test token');

    $params->{token} = $client_token;
    $params->{args}  = {id => $order->{id}};
    my $res = $c->call_ok(p2p_order_confirm => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'buyer-confirmed', 'Order is buyer confirmed';

    $params->{token} = $advertiser_token;
    $params->{args}  = {id => $order->{id}};
    $res             = $c->call_ok(p2p_order_confirm => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'completed', 'Order is completed';
    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Client cancellation' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});

    my $client_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    $params->{token} = $client_token;
    $params->{args}  = {id => $order->{id}};
    my $res = $c->call_ok(p2p_order_cancel => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'cancelled', 'Order is cancelled';

    $params->{args} = {id => 9999};
    $c->call_ok('p2p_order_cancel', $params)->has_no_system_error->has_error->error_code_is('OrderNotFound', 'Cancel non-existent order');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Getting order list' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => 10
    );

    my $client_token     = BOM::Platform::Token::API->new->create_token($client->loginid,     'test token');
    my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test token');

    $params->{token} = $advertiser_token;
    $params->{args}  = {advert_id => $advert->{id}};
    my $res1 = $c->call_ok(p2p_order_list => $params)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res1->{list}}), '==', 1, 'count of adverts is correct';

    BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => 10
    );

    my $res2 = $c->call_ok(p2p_order_list => $params)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res2->{list}}), '==', 2, 'count of orders is correct';

    $params->{token} = $client_token;
    $params->{args}  = {advert_id => $advert->{id}};
    my $res3 = $c->call_ok(p2p_order_list => $params)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res3->{list}}), '==', 1, 'count of orders is correct';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Order list pagination' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');

    BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => 10
    ) for (1 .. 2);

    my $param = {};
    $param->{token} = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test token');

    my $res1 = $c->call_ok(p2p_order_list => $param)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res1->{list}}), '==', 2, 'Got 2 orders in a list';

    my ($first_order, $second_order) = @{$res1->{list}};

    $param->{args} = {limit => 1};
    my $res2 = $c->call_ok(p2p_order_list => $param)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res2->{list}}), '==', 1, 'got 1 order with limit 1';
    cmp_ok $res2->{list}[0]{id}, 'eq', $first_order->{id}, 'got correct order id with limit 1';

    $param->{args} = {
        limit  => 1,
        offset => 1
    };
    my $res3 = $c->call_ok(p2p_order_list => $param)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res3->{list}}), '==', 1, 'got 1 order with limit 1 and offest 1';
    cmp_ok $res3->{list}[0]{id}, 'eq', $second_order->{id}, 'got correct order id with limit 1 and offset 1';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Getting order list' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert1) = BOM::Test::Helper::P2P::create_advert(type => 'sell');

    my $advertiser1_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test token');
    $params->{token} = $advertiser1_token;
    $params->{args}  = {advertiser_id => $advertiser->p2p_advertiser_info->{id}};
    my $res1 = $c->call_ok(p2p_advert_list => $params)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res1->{list}}), '==', 1, 'count of adverts is correct';

    my ($advertiser2, $advert2) = BOM::Test::Helper::P2P::create_advert(type => 'sell');

    my $advertiser2_token = BOM::Platform::Token::API->new->create_token($advertiser2->loginid, 'test token');
    $params->{token} = $advertiser2_token;
    $params->{args}  = {advertiser_id => $advertiser2->p2p_advertiser_info->{id}};
    my $res2 = $c->call_ok(p2p_advert_list => $params)->has_no_system_error->has_no_error->result;
    cmp_ok scalar(@{$res2->{list}}), '==', 1, 'count of adverts is correct';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Sell orders' => sub {
    my $amount = 100;

    BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'buy'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        balance   => $amount
    );

    my $client_token     = BOM::Platform::Token::API->new->create_token($client->loginid,     'test token');
    my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test token');

    $params->{token} = $advertiser_token;
    $params->{args}  = {id => $order->{id}};
    my $res = $c->call_ok(p2p_order_confirm => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'buyer-confirmed', 'Order is buyer confirmed';

    $params->{token} = $client_token;
    $params->{args}  = {id => $order->{id}};
    $res             = $c->call_ok(p2p_order_confirm => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'completed', 'Order is completed';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Order dispute (type buy)' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});

    my $client_token     = BOM::Platform::Token::API->new->create_token($client->loginid,     'test token');
    my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test token2');
    BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
    $params->{token} = $client_token;
    $params->{args}  = {
        id             => $order->{id},
        dispute_reason => 'seller_not_released',
    };
    my $res = $c->call_ok(p2p_order_dispute => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'disputed', 'Order status is disputed';
    is $res->{dispute_details}->{dispute_reason}, 'seller_not_released', 'Dispute reason is properly set';
    is $res->{dispute_details}->{disputer_loginid}, $client->loginid, 'Client is the disputer';

    subtest 'Error scenarios for dispute' => sub {
        $params->{args} = {id => $order->{id} * -1};
        $c->call_ok('p2p_order_dispute', $params)->has_no_system_error->has_error->error_code_is('OrderNotFound', 'Dispute non-existent order');

        $params->{args} = {
            id             => $order->{id},
            dispute_reason => 'buyer_not_paid',
        };
        $c->call_ok('p2p_order_dispute', $params)->has_no_system_error->has_error->error_code_is('InvalidReasonForBuyer', 'Invalid reason for buyer');

        $params->{args} = {
            id             => $order->{id},
            dispute_reason => 'seller_not_released',
        };
        $params->{token} = $advertiser_token;
        $c->call_ok('p2p_order_dispute', $params)
            ->has_no_system_error->has_error->error_code_is('InvalidReasonForSeller', 'Invalid reason for seller');

        BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
        my $user_third_party = BOM::User->create(
            email    => 'some@strange.com',
            password => 'test'
        );
        my $third_party = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            email       => 'some@strange.com'
        });
        $user_third_party->add_client($third_party);
        $third_party->set_default_account('USD');

        my $token_third_party = BOM::Platform::Token::API->new->create_token($third_party->loginid, 'third party token');
        $params->{token} = $token_third_party;
        $params->{args}  = {
            id             => $order->{id},
            dispute_reason => 'seller_not_released'
        };

        $c->call_ok('p2p_order_dispute', $params)->has_no_system_error->has_error->error_code_is('OrderNotFound', 'Invalid client');
        $params->{token} = $client_token;
        $params->{args}  = {
            id             => $order->{id},
            dispute_reason => 'seller_not_released'
        };

        BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'pending');
        $c->call_ok('p2p_order_dispute', $params)
            ->has_no_system_error->has_error->error_code_is('InvalidStateForDispute', 'Invalid state for dispute');

        BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'cancelled');
        $c->call_ok('p2p_order_dispute', $params)
            ->has_no_system_error->has_error->error_code_is('InvalidFinalStateForDispute', 'Invalid final state for dispute');

        BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'disputed');
        $c->call_ok('p2p_order_dispute', $params)
            ->has_no_system_error->has_error->error_code_is('OrderUnderDispute', 'Order is already under dispute');

        BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'completed');
        $c->call_ok('p2p_order_dispute', $params)
            ->has_no_system_error->has_error->error_code_is('InvalidFinalStateForDispute', 'Invalid final state for dispute');

    };

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Dispute edge cases' => sub {
    # FE relies on expire time to show the complain button
    # So `buyer-confirmed` status may raise a dispute when order is expired

    for my $status (qw/buyer-confirmed/) {
        subtest $status => sub {
            BOM::Test::Helper::P2P::create_escrow();
            my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
            my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});

            my $client_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
            BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});    # This expires the order
            BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, $status);
            $params->{token} = $client_token;
            $params->{args}  = {
                id             => $order->{id},
                dispute_reason => 'buyer_overpaid',
            };
            my $res = $c->call_ok(p2p_order_dispute => $params)->has_no_system_error->has_no_error->result;
            is $res->{status}, 'disputed', 'Order status is disputed';
            is $res->{dispute_details}->{dispute_reason}, 'buyer_overpaid', 'Dispute reason is properly set';
            is $res->{dispute_details}->{disputer_loginid}, $client->loginid, 'Client is the disputer';
        }
    }
};

subtest 'Order dispute (type sell)' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'buy'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        balance   => $amount
    );

    my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test token');

    $params->{token} = $advertiser_token;
    $params->{args}  = {
        id             => $order->{id},
        dispute_reason => 'buyer_overpaid',
    };

    BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
    my $res = $c->call_ok(p2p_order_dispute => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'disputed', 'Order status is disputed';
    is $res->{dispute_details}->{dispute_reason}, 'buyer_overpaid', 'Dispute reason is properly set';
    is $res->{dispute_details}->{disputer_loginid}, $advertiser->loginid, 'Advertiser is the disputer';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Advertiser stats' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        balance   => $amount
    );

    my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test token');

    $params->{token} = $advertiser_token;
    $params->{args}  = {
        id             => $order->{id},
        dispute_reason => 'buyer_overpaid',
    };

    BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
    my $res = $c->call_ok(p2p_order_dispute => $params)->has_no_system_error->has_no_error->result;
    is $res->{status}, 'disputed', 'Order status is disputed';
    is $res->{dispute_details}->{dispute_reason}, 'buyer_overpaid', 'Dispute reason is properly set';
    is $res->{dispute_details}->{disputer_loginid}, $advertiser->loginid, 'Advertiser is the disputer';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Advertiser stats' => sub {
    BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
    );
    $client->p2p_order_confirm(id => $order->{id});
    $advertiser->p2p_order_confirm(id => $order->{id});

    my $client_token     = BOM::Platform::Token::API->new->create_token($client->loginid,     'test token');
    my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test token');

    my $params = {
        token => $advertiser_token,
    };

    my $res_adv = $c->call_ok(p2p_advertiser_stats => $params)->has_no_system_error->has_no_error->result;

    is $res_adv->{sell_orders_count},  1, 'sell_orders_created';
    is $res_adv->{total_orders_count}, 1, 'total_orders_created';

    $params = {
        token => $client_token,
        args  => {id => $advertiser->p2p_advertiser_info->{id}},
    };
    my $res_cli = $c->call_ok(p2p_advertiser_stats => $params)->has_no_system_error->has_no_error->result;

    cmp_deeply($res_adv, $res_cli, 'stats match when requested in different ways');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'P2P Order Info' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'buy'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        balance   => $amount
    );

    my $client_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    $params->{token} = $client_token;
    $params->{args}  = {
        id => $order->{id},
    };

    my $res = $c->call_ok(p2p_order_info => $params)->has_no_system_error->has_no_error->result;
    cmp_deeply $res,
        {
        chat_channel_url => '',
        rate_display     => '1.00',
        local_currency   => 'myr',
        amount           => '100.00',
        client_details   => {
            name    => 'test advertiser 39',
            id      => re('\d+'),
            loginid => 'CR10055'
        },
        price_display  => 100,
        expiry_time    => re('\d+'),
        amount_display => '100.00',
        advert_details => {
            payment_method => 'bank_transfer',
            id             => re('\d+'),
            description    => 'Test advert',
            type           => 'buy'
        },
        payment_info       => 'Bank: 123456',
        created_time       => re('\d+'),
        is_incoming        => 0,
        advertiser_details => {
            loginid => 'CR10054',
            id      => re('\d+'),
            name    => 'test advertiser 38'
        },
        contact_info     => 'Tel: 123456',
        type             => 'sell',
        status           => 'pending',
        id               => re('\d+'),
        price            => 100,
        account_currency => 'USD',
        rate             => 1,
        dispute_details  => {
            disputer_loginid => undef,
            dispute_reason   => undef
        },
        stash => {
            source_bypass_verification => 0,
            app_markup_percentage      => '0',
            valid_source               => 1
        }};
};

subtest 'RestrictedCountry error before PermissionDenied' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'buy'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        balance   => $amount
    );

    my $client_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    $params->{token} = $client_token;
    $params->{args}  = {
        id => $advertiser->{id},
    };

    # Set unwelcome to client
    $client->status->set('unwelcome');
    # Set restricted country and client residence to py
    $app_config->payments->p2p->restricted_countries(['py']);
    $client->residence('py');
    $client->save;
    my $res = $c->call_ok(p2p_advertiser_info => $params)->has_no_system_error->result;
    is $res->{error}->{code}, 'RestrictedCountry', 'The expected error code is RestrictedCountry';
};

# restore app config
$app_config->system->suspend->p2p($p2p_suspend);
$app_config->payments->p2p->enabled($p2p_enable);

done_testing();
