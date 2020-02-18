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
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'sell',
    );
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,           'Escrow balance is correct');
    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');
    my $order_data = $client->p2p_order_create(
        advert_id   => $advert_info->{id},
        amount      => 100,
        expiry      => 7200,
        description => $order_description
    );

    ok($order_data, 'Order is created');

    ok($escrow->account->balance == $amount, 'Money is deposited to Escrow account');
    ok($advertiser->account->balance == 0,   'Money is withdrawn from advertiser account');
    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{amount} == $amount, 'Amount for new order is correct');
    is($order_data->{description}, $order_description, 'Description for new order is correct');

    BOM::Test::Helper::P2P::reset_escrow();

    my $expected_order = {
        account_currency => $advert_info->{account_currency},
        amount           => num($order_data->{amount}),
        amount_display   => num($order_data->{amount}),
        created_time     => re('\d+'),
        description      => $order_data->{description},
        expiry_time      => re('\d+'),
        id               => $order_data->{id},
        is_incoming      => 0,
        local_currency   => $advert_info->{local_currency},
        price            => num($advert_info->{rate} * 100),
        price_display    => num($advert_info->{rate} * 100),
        rate             => num($advert_info->{rate}),
        rate_display     => num($advert_info->{rate}),
        status           => 'pending',
        type             => $order_data->{type},
        advert_details   => {
            id          => $advert_info->{id},
            description => $advert_info->{description},
            type        => $advert_info->{type},
        },
        advertiser_details => {
            id   => $advertiser->p2p_advertiser_info->{id},
            name => $advertiser->p2p_advertiser_info->{name},
        },
    };

    cmp_deeply($client->p2p_order_list, [$expected_order], 'order_list() returns correct info');
    cmp_deeply($client->p2p_order_info(id => $order_data->{id}), $expected_order, 'order_info() returns correct info');
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
        advert_id   => $advert_info->{id},
        amount      => 50,
        expiry      => 7200,
        description => $order_description
    );

    ok($order_data1, 'Order is created');

    ok($escrow->account->balance == 50,     'Money is deposited to Escrow account for first order');
    ok($advertiser->account->balance == 50, 'Money is withdrawn from advertiser account for first order');

    is($order_data1->{status}, 'pending', 'Status for new order is correct');
    ok($order_data1->{amount} == 50, 'Amount for new order is correct');
    is($order_data1->{description}, $order_description, 'Description for new order is correct');

    my $order_data2 = $client2->p2p_order_create(
        advert_id   => $advert_info->{id},
        amount      => 50,
        expiry      => 7200,
        description => $order_description
    );

    ok($order_data2, 'Order is created');

    ok($escrow->account->balance == 100,   'Money is deposited to Escrow account for second order');
    ok($advertiser->account->balance == 0, 'Money is withdrawn from advertiser account for second order');

    is($order_data2->{status}, 'pending', 'Status for new order is correct');
    ok($order_data2->{amount} == 50, 'Amount for new order is correct');
    is($order_data2->{description}, $order_description, 'Description for new order is correct');

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
        advert_id   => $advert_info_1->{id},
        amount      => 100,
        expiry      => 7200,
        description => $order_description
    );

    ok($order_data1, 'Order is created');

    ok($escrow->account->balance == 100,    'Money is deposited to Escrow account for first order');
    ok($advertiser1->account->balance == 0, 'Money is withdrawn from advertiser account for first order');

    is($order_data1->{status}, 'pending', 'Status for new order is correct');
    ok($order_data1->{amount} == 100, 'Amount for new order is correct');
    is($order_data1->{description}, $order_description, 'Description for new order is correct');

    my $order_data2 = $client->p2p_order_create(
        advert_id   => $advert_info_2->{id},
        amount      => 100,
        expiry      => 7200,
        description => $order_description
    );

    ok($order_data2, 'Order is created');

    ok($escrow->account->balance == 200,    'Money is deposited to Escrow account for second order');
    ok($advertiser2->account->balance == 0, 'Money is withdrawn from advertiser account for second order');

    is($order_data2->{status}, 'pending', 'Status for new order is correct');
    ok($order_data2->{amount} == 100, 'Amount for new order is correct');
    is($order_data2->{description}, $order_description, 'Description for new order is correct');

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
        advert_id   => $advert_info->{id},
        amount      => 50,
        expiry      => 7200,
        description => $order_description
    );

    ok($order_data, 'Order is created');

    ok($escrow->account->balance == 50,     'Money is deposited to Escrow account for first order');
    ok($advertiser->account->balance == 50, 'Money is withdrawn from advertiser account for first order');

    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{amount} == 50, 'Amount for new order is correct');
    is($order_data->{description}, $order_description, 'Description for new order is correct');

    my $err = exception {
        $client->p2p_order_create(
            advert_id   => $advert_info->{id},
            amount      => 50,
            expiry      => 7200,
            description => $order_description
        );
    };
    is $err->{error_code}, 'OrderAlreadyExists', 'Got correct error';

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
            advert_id   => $advert_info->{id},
            amount      => 100,
            expiry      => 7200,
            description => $order_description
        );
    };
    is $err->{error_code}, 'InvalidAdvertOwn', 'Got correct error code';

    ok($escrow->account->balance == 0,           'Escrow balance is correct');
    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order with amount more than available' => sub {
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
            advert_id   => $advert_info->{id},
            amount      => 101,
            expiry      => 7200,
            description => $order_description
        );
    };
    is $err->{error_code}, 'OrderMaximumExceeded', 'Got correct error code';

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
            advert_id   => $advert_info->{id},
            amount      => -1,
            expiry      => 7200,
            description => $order_description
        );
    };
    is $err->{error_code}, 'OrderMinimumNotMet', 'Got correct error code';

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
            advert_id   => $advert_info->{id},
            amount      => $min_amount - 1,
            expiry      => 7200,
            description => $order_description
        );
    };
    is $err->{error_code}, 'OrderMinimumNotMet', 'Got correct error code';
    cmp_bag($err->{message_params}, [$account_currency, formatnumber('amount', $account_currency, $min_amount)], 'Got correct error values');

    $err = exception {
        $client->p2p_order_create(
            advert_id   => $advert_info->{id},
            amount      => $max_amount + 1,
            expiry      => 7200,
            description => $order_description
        );
    };
    is $err->{error_code}, 'OrderMaximumExceeded', 'Got correct error code';
    cmp_bag($err->{message_params}, [$account_currency, formatnumber('amount', $account_currency, $max_amount)], 'Got correct error values');

    ok($escrow->account->balance == 0,           'Escrow balance is correct');
    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Creating order with disabled advertiser' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'sell'
    );
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,           'Escrow balance is correct');
    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    $advertiser->p2p_advertiser_update(is_listed => 0);

    my $err = exception {
        $client->p2p_order_create(
            advert_id   => $advert_info->{id},
            amount      => $amount,
            expiry      => 7200,
            description => $order_description
        );
    };

    is $err->{error_code}, 'AdvertiserNotListed', 'Got correct error code';

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
            advert_id   => $advert_info->{id},
            amount      => $amount,
            expiry      => 7200,
            description => $order_description
        );
    };
    is $err->{error_code}, 'EscrowNotFound', 'Got correct error code';

    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    BOM::Config::Runtime->instance->app_config->payments->p2p->escrow($original_escrow);
};

subtest 'Creating order with wrong currency' => sub {
    my $amount      = 100;
    my $description = 'Test order';

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'sell'
    );

    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('EUR');

    my $err = exception {
        $client->p2p_order_create(
            advert_id   => $advert_info->{id},
            amount      => $amount,
            expiry      => 7200,
            description => $description
        );
    };
    is $err->{error_code}, 'InvalidOrderCurrency', 'Got correct error code';

    ok($advertiser->account->balance == $amount, 'advertiser balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Buy adverts' => sub {
    my $amount = 100;

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'buy'
    );
    my $client = BOM::Test::Helper::P2P::create_client();

    ok($escrow->account->balance == 0,     'Escrow balance is correct');
    ok($advertiser->account->balance == 0, 'advertiser balance is correct');
    note $advertiser->account->balance;
    my %params = (
        advert_id   => $advert_info->{id},
        amount      => 100,
        expiry      => 7200,
        description => $order_description
    );
    my $err = exception {
        warning_like { $client->p2p_order_create(%params) } qr/check_no_negative_balance/;
    };
    is $err->{error_code}, 'InsufficientBalance', 'error for insufficient client balance';

    BOM::Test::Helper::Client::top_up($client, $client->currency, $amount);

    my $order_data = $client->p2p_order_create(%params);

    ok($order_data, 'Order is created');

    ok($escrow->account->balance == $amount, 'Money is deposited to Escrow account');
    ok($client->account->balance == 0,       'Money is withdrawn from Client account');

    is($order_data->{status}, 'pending', 'Status for new order is correct');
    ok($order_data->{amount} == $amount, 'Amount for new order is correct');
    is($order_data->{description},          $order_description,                'Description for new order is correct');
    is($order_data->{advert_details}{type}, $advert_info->{type},              'advert type is correct');
    is($order_data->{type},                 $advert_info->{counterparty_type}, 'order type is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

done_testing();
