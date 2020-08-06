use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;
use Test::MockModule;
use Test::Exception;
use Format::Util::Numbers qw(formatnumber);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use Test::Fatal;
use Test::MockModule;

populate_exchange_rates();

BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([]);
BOM::Test::Helper::P2P::bypass_sendbird();

my %last_event;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;
        %last_event = (
            type => $type,
            data => $data
        );
    });

subtest 'Creating new buy order' => sub {

    my %ad_params = (
        amount         => 100,
        rate           => 1.1,
        type           => 'sell',
        description    => 'ad description',
        payment_method => 'bank_transfer',
        payment_info   => 'ad pay info',
        contact_info   => 'ad contact info',
        local_currency => 'sgd',
    );

    my $escrow = BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(%ad_params, advertiser => {first_name=>'john',last_name=>'smith'});
  
    my $client = BOM::Test::Helper::P2P::create_client(undef, {first_name=>'mary', last_name=>'jane'});

    ok($escrow->account->balance == 0,                      'Escrow balance is correct');
    ok($advertiser->account->balance == $ad_params{amount}, 'advertiser balance is correct');

    my $order_amount = 100;

    my $err = exception {
        $client->p2p_order_create(
            advert_id    => $advert_info->{id},
            amount       => $order_amount,
            expiry       => 7200,
            payment_info => 'blah',
            contact_info => 'blah',
        );
    };
    is $err->{error_code}, 'OrderPaymentContactInfoNotAllowed', 'Cannot provide payment/contact info for buy order';

    my $new_order = $client->p2p_order_create(
        advert_id => $advert_info->{id},
        amount    => $order_amount,
        expiry    => 7200,
    );

    ok($escrow->account->balance == $order_amount, 'Money is deposited to Escrow account');
    ok($advertiser->account->balance == 0,         'Money is withdrawn from advertiser account');

    cmp_deeply(
       \%last_event,
        { type => 'p2p_order_created', data => { client_loginid => $client->loginid, order_id => $new_order->{id} } },
        'p2p_order_created event emitted'
    );

    BOM::Test::Helper::P2P::reset_escrow();

    my $expected_order = {
        account_currency => $advertiser->account->currency_code,
        amount           => num($order_amount),
        amount_display   => num($order_amount),
        created_time     => re('\d+'),
        expiry_time      => re('\d+'),
        id               => $new_order->{id},
        is_incoming      => 0,
        local_currency   => $ad_params{local_currency},
        price            => num($ad_params{amount} * $ad_params{rate}),
        price_display    => num($ad_params{amount} * $ad_params{rate}),
        rate             => num($ad_params{rate}),
        rate_display     => num($ad_params{rate}),
        status           => 'pending',
        type             => 'buy',
        payment_info     => $ad_params{payment_info},
        contact_info     => $ad_params{contact_info},
        chat_channel_url => '',
        advert_details   => {
            id             => $advert_info->{id},
            description    => $ad_params{description},
            type           => $ad_params{type},
            payment_method => $ad_params{payment_method}
        },
        client_details => {
            id         => '',
            name       => '',
            first_name => 'mary',
            last_name  => 'jane',
            loginid    => $client->loginid,
        },
        advertiser_details => {
            id         => $advertiser->p2p_advertiser_info->{id},
            name       => $advertiser->p2p_advertiser_info->{name},
            first_name => 'john',
            last_name  => 'smith',
            loginid    => $advertiser->loginid,
        },
    };
    cmp_deeply($new_order, $expected_order, 'order_create expected response');
    cmp_deeply($client->p2p_order_list, [$expected_order], 'order_list() returns correct info');
    cmp_deeply($client->p2p_order_info(id => $new_order->{id}), $expected_order, 'order_info() returns correct info');
};

subtest 'Creating two orders from two clients' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'sell'
    );
    my $client1 = BOM::Test::Helper::P2P::create_client();
    my $client2 = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,           'Escrow balance is correct');
    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    my $order_data1 = $client1->p2p_order_create(
        advert_id => $advert_info->{id},
        amount    => 50,
        expiry    => 7200,
    );

    ok($order_data1, 'Order is created');

    ok($escrow->account->balance == 50,     'Money is deposited to Escrow account for first order');
    ok($advertiser->account->balance == 50, 'Money is withdrawn from advertiser account for first order');

    is($order_data1->{status}, 'pending', 'Status for new order is correct');
    ok($order_data1->{amount} == 50, 'Amount for new order is correct');

    my $order_data2 = $client2->p2p_order_create(
        advert_id => $advert_info->{id},
        amount    => 50,
        expiry    => 7200,
    );

    ok($order_data2, 'Order is created');

    ok($escrow->account->balance == 100,   'Money is deposited to Escrow account for second order');
    ok($advertiser->account->balance == 0, 'Money is withdrawn from advertiser account for second order');

    is($order_data2->{status}, 'pending', 'Status for new order is correct');
    ok($order_data2->{amount} == 50, 'Amount for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating two orders from one client for two adverts' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser1, $advert_info_1) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'sell'
    );
    my ($advertiser2, $advert_info_2) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'sell'
    );
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,            'Escrow balance is correct');
    ok($advertiser1->account->balance == $amount, 'advertiser balance is correct');
    ok($advertiser2->account->balance == $amount, 'advertiser balance is correct');

    my $order_data1 = $client->p2p_order_create(
        advert_id => $advert_info_1->{id},
        amount    => 100,
        expiry    => 7200
    );

    ok($order_data1, 'Order is created');

    ok($escrow->account->balance == 100,    'Money is deposited to Escrow account for first order');
    ok($advertiser1->account->balance == 0, 'Money is withdrawn from advertiser account for first order');

    is($order_data1->{status}, 'pending', 'Status for new order is correct');
    ok($order_data1->{amount} == 100, 'Amount for new order is correct');

    my $order_data2 = $client->p2p_order_create(
        advert_id => $advert_info_2->{id},
        amount    => 100,
        expiry    => 7200,
    );

    ok($order_data2, 'Order is created');

    ok($escrow->account->balance == 200,    'Money is deposited to Escrow account for second order');
    ok($advertiser2->account->balance == 0, 'Money is withdrawn from advertiser account for second order');

    is($order_data2->{status}, 'pending', 'Status for new order is correct');
    ok($order_data2->{amount} == 100, 'Amount for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating two new orders from one client for one advert' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'sell'
    );
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,           'Escrow balance is correct');
    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    my $order_data = $client->p2p_order_create(
        advert_id => $advert_info->{id},
        amount    => 50,
        expiry    => 7200,
    );

    ok($order_data, 'Order is created');

    ok($escrow->account->balance == 50,     'Money is deposited to Escrow account for first order');
    ok($advertiser->account->balance == 50, 'Money is withdrawn from advertiser account for first order');

    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{amount} == 50, 'Amount for new order is correct');

    my $err = exception {
        $client->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => 50,
            expiry    => 7200,
        );
    };
    is $err->{error_code}, 'OrderAlreadyExists', 'Could not create order, got error code OrderAlreadyExists';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order for advertiser own order' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'sell'
    );

    ok($escrow->account->balance == 0,           'Escrow balance is correct');
    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    my $err = exception {
        $advertiser->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => 100,
            expiry    => 7200,
        );
    };
    is $err->{error_code}, 'InvalidAdvertOwn', 'Got correct error code';

    ok($escrow->account->balance == 0,           'Escrow balance is correct');
    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order with negative amount' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'sell'
    );
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,           'Escrow balance is correct');
    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    my $err = exception {
        $client->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => -1,
            expiry    => 7200,
        );
    };
    is $err->{error_code}, 'OrderMinimumNotMet', 'Could not create order, got error code OrderMinimumNotMet';

    ok($escrow->account->balance == 0,           'Escrow balance is correct');
    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order outside min-max range' => sub {
    my $amount     = 100;
    my $min_amount = 20;
    my $max_amount = 50;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount           => $amount,
        min_order_amount => $min_amount,
        max_order_amount => $max_amount,
        type             => 'sell',
    );
    my $account_currency = $advertiser->account->currency_code;
    my $client           = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,           'Escrow balance is correct');
    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    my $err = exception {
        $client->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => $min_amount - 1,
            expiry    => 7200,
        );
    };
    is $err->{error_code}, 'OrderMinimumNotMet', 'Could not create order, got error code OrderMinimumNotMet';
    cmp_bag($err->{message_params}, [$account_currency, formatnumber('amount', $account_currency, $min_amount)], 'Got correct error values');

    $err = exception {
        $client->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => $max_amount + 1,
            expiry    => 7200,
        );
    };
    is $err->{error_code}, 'OrderMaximumExceeded', 'Got correct error code';
    cmp_bag($err->{message_params}, [$account_currency, formatnumber('amount', $account_currency, $max_amount)], 'Got correct error values');

    ok($escrow->account->balance == 0,           'Escrow balance is correct');
    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order without escrow' => sub {
    my $amount = 100;

    my $original_escrow = BOM::Config::Runtime->instance->app_config->payments->p2p->escrow;
    BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([]);

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'sell'
    );
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    my $err = exception {
        $client->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => $amount,
            expiry    => 7200,
        );
    };
    is $err->{error_code}, 'EscrowNotFound', 'EscrowNotFound';

    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    BOM::Config::Runtime->instance->app_config->payments->p2p->escrow($original_escrow);
};

subtest 'Buyer tries to place an order for an advert with a different currency' => sub {
    my $amount      = 100;
    my $description = 'Test order';

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'sell'
    );

    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('EUR');

    isnt $client->account->currency_code, $advertiser->account->currency_code, 'Advertiser and buyer has different currencies';

    my $err = exception {
        $client->p2p_order_create(
            advert_id   => $advert_info->{id},
            amount      => $amount,
            expiry      => 7200,
            description => $description
        );
    };
    is $err->{error_code}, 'AdvertNotFound', 'Could not create order, got error code AdvertNotFound';

    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Buyer tries to place an order for an advert of another country' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'sell'
    );

    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('USD');
    $client->residence('MY');

    my $err = exception {
        $client->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => $amount,
            expiry    => 7200,
        );
    };
    is $err->{error_code}, 'AdvertNotFound', 'Could not create order, got error code AdvertNotFound';

    ok $escrow->account->balance == 0, 'The escrow balance did not change';
    ok $advertiser->account->balance == $amount, 'The advertiser balance did not change';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Buy adverts' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount         => $amount,
        type           => 'buy',
        payment_method => 'bank_transfer',
    );

    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,     'Escrow balance is correct');
    ok($advertiser->account->balance == 0, 'advertiser balance is correct');
    note $advertiser->account->balance;
    my %params = (
        advert_id    => $advert_info->{id},
        amount       => $amount,
        expiry       => 7200,
        payment_info => 'order pay info',
        contact_info => 'order contact info'
    );

    BOM::Test::Helper::Client::top_up($client, $client->currency, $amount);

    my $err = exception { $client->p2p_order_create(%params, payment_info => undef) };
    is $err->{error_code}, 'OrderPaymentInfoRequired', 'error for empty payment info';

    $err = exception { $client->p2p_order_create(%params, contact_info => undef) };
    is $err->{error_code}, 'OrderContactInfoRequired', 'error for empty contact info';

    my $order_data = $client->p2p_order_create(%params);

    ok($order_data, 'Order is created');

    ok($escrow->account->balance == $amount, 'Money is deposited to Escrow account');
    ok($client->account->balance == 0,       'Money is withdrawn from Client account');

    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{amount} == $amount, 'Amount for new order is correct');
    is($order_data->{advert_details}{type}, $advert_info->{type},              'advert type is correct');
    is($order_data->{type},                 $advert_info->{counterparty_type}, 'order type is correct');
    is($order_data->{payment_info},         $params{payment_info},             'payment_info is correct');
    is($order_data->{contact_info},         $params{contact_info},             'contact_info is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Buyer tries to place an order for an advert of a non-approved advertiser' => sub {
    my $escrow    = BOM::Test::Helper::P2P::create_escrow();
    my $ad_amount = 100;

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount           => $ad_amount,
        max_order_amount => $ad_amount,
        type             => 'sell'
    );

    $advertiser->p2p_advertiser_update(is_approved => 0);

    ok !($advertiser->p2p_advertiser_info->{is_approved}), 'The advertiser is not approved';

    my $buyer        = BOM::Test::Helper::Client::create_client();
    my $order_amount = $ad_amount;

    my $err = exception {
        $buyer->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => $order_amount
            )
    };

    is $err->{error_code}, 'AdvertNotFound', 'Could not create order, got error code AdvertNotFound';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Buyer tries to place an order for an advert of a non-listed advertiser' => sub {
    my $escrow    = BOM::Test::Helper::P2P::create_escrow();
    my $ad_amount = 100;

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount           => $ad_amount,
        max_order_amount => $ad_amount,
        type             => 'sell'
    );

    $advertiser->p2p_advertiser_update(is_listed => 0);

    ok !($advertiser->p2p_advertiser_info->{is_listed}), 'The advertiser is not listed';

    my $buyer        = BOM::Test::Helper::Client::create_client();
    my $order_amount = $ad_amount;

    my $err = exception {
        $buyer->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => $order_amount
            )
    };

    is $err->{error_code}, 'AdvertNotFound', 'Could not create order, got error code AdvertNotFound';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Buyer with empty balance tries to place an "sell" order' => sub {
    my $escrow    = BOM::Test::Helper::P2P::create_escrow();
    my $ad_amount = 100;

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount           => $ad_amount,
        max_order_amount => $ad_amount,
        type             => 'buy'
    );

    my $buyer = BOM::Test::Helper::Client::create_client();
    $buyer->account('USD');

    cmp_ok $buyer->account->balance, '==', 0, "The buyer's balance is 0";

    my $err = exception {
        $buyer->p2p_order_create(
            advert_id    => $advert_info->{id},
            amount       => $ad_amount,
            payment_info => 'payment info',
            contact_info => 'contact info',
            )
    };

    is $err->{error_code}, 'AdvertNotFound', 'Could not create order, got error code AdvertNotFound';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Buyer tries to place an order for an inactive ad' => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();

    my $ad_amount = 100;

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount           => $ad_amount,
        max_order_amount => $ad_amount,
        type             => 'buy'
    );

    ok $advertiser->p2p_advert_update(
        id        => $advert_info->{id},
        is_active => 0
        ),
        'The advert is inactive';

    my $buyer = BOM::Test::Helper::Client::create_client();

    my $err = exception {
        $buyer->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => $ad_amount,
            )
    };

    is $err->{error_code}, 'AdvertNotFound', 'Could not create order, got error code AdvertNotFound';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Buyer tries to place a "buy" order with an amount that exceeds the advertiser balance' => sub {
    BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert(100);

    my $ad_amount = 100;
    my $escrow    = BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount           => $ad_amount,
        max_order_amount => $ad_amount,
        type             => 'sell'
    );

    BOM::Test::Helper::Client::top_up($advertiser, $advertiser->currency, -50);

    my $buyer        = BOM::Test::Helper::Client::create_client();
    my $order_amount = 70;

    ok $advertiser->account->balance < $order_amount, 'The advertiser balance is less that the order amount';

    my $err = exception {
        $buyer->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => $order_amount
            )
    };

    is $err->{error_code}, 'OrderMaximumExceeded', 'Could not create order, got error code OrderMaximumExceeded';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Buyer tries to place an order bigger than the ad amount' => sub {
    my $escrow    = BOM::Test::Helper::P2P::create_escrow();
    my $ad_amount = 100;

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount           => $ad_amount,
        max_order_amount => $ad_amount,
        type             => 'buy'
    );

    my $buyer = BOM::Test::Helper::Client::create_client();
    $buyer->account('USD');

    cmp_ok $buyer->account->balance, '==', 0, 'The buyer balance is 0';

    my $err = exception {
        $buyer->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => $advert_info->{amount} * 2
            )
    };

    is $err->{error_code}, 'AdvertNotFound', 'Could not create order, got error code AdvertNotFound';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Buyer tries to place an order for an advert of an unapproved advertiser' => sub {
    BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert(100);
    BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(type => 'sell');

    $advertiser->p2p_advertiser_update(is_approved => 0);

    ok !($advertiser->p2p_advertiser_info->{is_approved}), 'The advertiser is not approved';

    my $buyer = BOM::Test::Helper::Client::create_client();
    my $err   = exception {
        $buyer->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => $advert_info->{amount})
    };

    is $err->{error_code}, 'AdvertNotFound', 'Could not create order, got error code AdvertNotFound';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Daily order limit' => sub {
    BOM::Config::Runtime->instance->app_config->payments->p2p->limits->count_per_day_per_client(2);
    BOM::Test::Helper::P2P::create_escrow();

    my $buyer = BOM::Test::Helper::P2P::create_client();

    for (1 .. 2) {
        my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
            type   => 'sell',
            amount => 100
        );
        $buyer->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => 10
        );
    }

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        type   => 'sell',
        amount => 100
    );

    my $err = exception {
        $buyer->p2p_order_create(
            advert_id => $advert_info->{id},
            amount    => 10
        );
    };

    is $err->{error_code}, 'ClientDailyOrderLimitExceeded', 'Could not create order, got error code ClientDailyOrderLimitExceeded';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Order view permissions' => sub {

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert();
    my ($client1, $order) = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});
    my $client2 = BOM::Test::Helper::P2P::create_client();
    
    ok $client1->p2p_order_info(id => $order->{id}), "order_info: cannot see own order";
    ok !$client2->p2p_order_info(id => $order->{id}), "order_info: cannot see other client's orders";

    ok $client1->p2p_order_list(id => $order->{id}), "order_list: cannot see own order";
    ok !$client2->p2p_order_list(id => $order->{id})->@*, "order_list: cannot see other client's orders";

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'payment validation' => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type=>'sell');    
    my $client = BOM::Test::Helper::P2P::create_client(1000);
    my $mock_client = Test::MockModule->new('BOM::User::Client');

    $mock_client->mock(
        'validate_payment', sub {
            my ($self, %args) = @_;
            if ($self->loginid eq $client->loginid) {
                 ok $args{amount} > 0, 'sell ad is validated as client deposit';
                 die "fail client reason\n";
            }
    });

    my $err = exception {
        $client->p2p_order_create(
            advert_id => $advert->{id},
            amount    => 10
        );
    };
    cmp_deeply($err, {error_code => 'OrderCreateFailClient', message_params => ['fail client reason']}, 'Client validate_payment failed error has details');

    $mock_client->mock(
        'validate_payment', sub {
            my ($self, %args) = @_;
            if ($self->loginid eq $advertiser->loginid) {
                 ok $args{amount} < 0, 'sell ad is validated as advertiser withdrawal';
                 die "fail advertiser reason\n";
            }
    });

    $err = exception {
        $client->p2p_order_create(
            advert_id => $advert->{id},
            amount    => 10
        );
    };
    cmp_deeply($err, {error_code => 'OrderCreateFailAdvertiser'}, 'Advertiser validate_payment failed error has no details');
    
    ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type=>'buy');
    
    $mock_client->mock(
        'validate_payment', sub {
            my ($self, %args) = @_;
            if ($self->loginid eq $client->loginid) {
                 ok $args{amount} < 0, 'buy ad is validated as client withdrawal';
            }
            elsif ($self->loginid eq $advertiser->loginid) {
                ok $args{amount} > 0, 'buy ad is validated as advertiser deposit';
            }
            return $mock_client->original('validate_payment')->(@_);
    });    
    
    $err = exception {
        $client->p2p_order_create(
            advert_id => $advert->{id},
            amount    => 10,
            payment_info => 'x',
            contact_info => 'x',
        );
    };
    cmp_deeply($err, undef, 'validate_payment pass');
};

done_testing();
