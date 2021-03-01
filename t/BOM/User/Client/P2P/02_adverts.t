use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Exception;
use Test::Deep;
use List::Util qw(pairs);

use BOM::User::Client;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

BOM::Test::Helper::P2P::bypass_sendbird();

my $email = 'p2p_adverts_test@binary.com';

BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert(100);
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

my %advertiser_params = (
    default_advert_description => 'adv description',
    payment_info               => 'adv pay info',
    contact_info               => 'adv contact info',
);

my %advert_params = (
    account_currency  => 'USD',
    amount            => 100,
    description       => 'test advert',
    local_currency    => 'myr',
    max_order_amount  => 10,
    min_order_amount  => 0.1,
    payment_method    => 'camels',
    payment_info      => 'ad pay info',
    contact_info      => 'ad contact info',
    rate              => 1.23,
    type              => 'sell',
    counterparty_type => 'buy',
    payment_method    => 'bank_transfer',
);

subtest 'Creating advert from non-advertiser' => sub {
    my %params = %advert_params;

    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('USD');
    cmp_deeply(exception { $client->p2p_advert_create(%params) }, {error_code => 'AdvertiserNotRegistered'}, "non advertiser can't create advert");
};

subtest 'advertiser Registration' => sub {
    my $adv_client = BOM::Test::Helper::Client::create_client();
    $adv_client->account('USD');

    cmp_deeply(exception { $adv_client->p2p_advertiser_create() }, {error_code => 'AdvertiserNameRequired'}, 'Error when advertiser name is blank');

    my %params = (
        name => 'ad man 1',
        %advertiser_params
    );
    ok my $adv = $adv_client->p2p_advertiser_create(%params), 'create advertiser';

    my $expected = {
        id                    => $adv->{id},
        is_listed             => bool(1),
        is_approved           => bool(0),
        created_time          => bool(1),
        chat_user_id          => 'dummy',
        chat_token            => 'dummy',
        daily_buy             => num(0),
        daily_sell            => num(0),
        daily_buy_limit       => num(100),
        daily_sell_limit      => num(100),
        basic_verification    => 0,
        buy_completion_rate   => undef,
        buy_orders_count      => num(0),
        cancel_time_avg       => undef,
        full_verification     => 0,
        release_time_avg      => undef,
        sell_completion_rate  => undef,
        sell_orders_count     => num(0),
        total_completion_rate => undef,
        total_orders_count    => num(0),
        show_name             => 0,
        balance_available     => num(0),
        %params
    };

    my $advertiser_info = $adv_client->p2p_advertiser_info;
    cmp_deeply($advertiser_info, $expected, 'correct advertiser_info for advertiser');

    my $other_client = BOM::Test::Helper::P2P::create_advertiser();
    $advertiser_info = $other_client->p2p_advertiser_info(id => $adv->{id});
    delete $expected->@{
        qw/payment_info contact_info chat_user_id chat_token daily_buy daily_sell daily_buy_limit daily_sell_limit show_name balance_available/};
    cmp_deeply($advertiser_info, $expected, 'sensitve fields hidden in advertiser_info for other client');
};

subtest 'Duplicate advertiser Registration' => sub {
    my $name       = 'ad man 2';
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(name => $name);

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_create(%advertiser_params)
        },
        {error_code => 'AlreadyRegistered'},
        "cannot create second advertiser for a client"
    );

    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('USD');

    cmp_deeply(
        exception {
            $client->p2p_advertiser_create(name => $name)
        },
        {error_code => 'AdvertiserNameTaken'},
        "duplicate advertiser name not allowed"
    );
};

subtest 'Creating advert from not approved advertiser' => sub {
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();
    $advertiser->p2p_advertiser_update(is_approved => 0);

    cmp_deeply(
        exception {
            $advertiser->p2p_advert_create(%advert_params)
        },
        {error_code => 'AdvertiserNotApproved'},
        "non approved can't create advert"
    );
};

subtest 'Updating advertiser fields' => sub {

    my %params = (
        name => 'ad man 3',
        %advertiser_params
    );
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(%params);

    my $advertiser_info = $advertiser->p2p_advertiser_info;

    ok $advertiser_info->{is_approved},  'advertiser is approved';
    is $advertiser_info->{name},         $params{name}, 'advertiser name';
    ok $advertiser_info->{is_listed},    'advertiser is listed';
    is $advertiser_info->{chat_user_id}, 'dummy', 'advertiser chat user_id';

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_update(name => ' ');
        },
        {error_code => 'AdvertiserNameRequired'},
        'Error when advertiser name is blank'
    );

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_update(name => 'ad man 2');
        },
        {error_code => 'AdvertiserNameTaken'},
        'Cannot change to existing advertiser name'
    );

    is $advertiser->p2p_advertiser_update(name => 'test')->{name}, 'test', 'Changing name';

    is $advertiser->p2p_advertiser_update(name => 'test')->{name}, 'test', 'Do it again to ensure no duplicate error';

    ok !(
        $advertiser->p2p_advertiser_update(
            name      => 'test',
            is_listed => 0
        )->{is_listed}
        ),
        'Once more and switch flag is_listed to false';

    ok !($advertiser->p2p_advertiser_update(is_approved => 0)->{is_approved}), 'Disable approval';
    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_update(is_listed => 1);
        },
        {error_code => 'AdvertiserNotApproved'},
        'Error when advertiser is not approved'
    );

    ok $advertiser->p2p_advertiser_update(is_approved => 1)->{is_approved}, 'Enabling approval';
    ok $advertiser->p2p_advertiser_update(is_listed   => 1)->{is_listed},   'Switch flag is_listed to true';

    for my $pair (pairs('default_advert_description', 'new desc', 'contact_info', 'new contact info', 'payment_info', 'new pay info')) {
        is $advertiser->p2p_advertiser_update($pair->[0] => $pair->[1])->{$pair->[0]}, $pair->[1], 'update ' . $pair->[0];
    }
};

subtest 'Creating advert' => sub {

    my $name       = 'ad man 4';
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(
        %advertiser_params,
        name    => $name,
        balance => 2.4
    );

    my %params = %advert_params;
    for my $numeric_field (qw(amount max_order_amount min_order_amount rate)) {
        %params = %advert_params;

        $params{$numeric_field} = -1;
        cmp_deeply(
            exception {
                $advertiser->p2p_advert_create(%params);
            },
            {
                error_code => 'InvalidNumericValue',
                details    => {fields => [$numeric_field]},
            },
            "Error when numeric field '$numeric_field' is not greater than 0"
        );
    }

    %params = %advert_params;
    my $maximum_advert = BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert;
    $params{amount} = $maximum_advert + 1;
    cmp_deeply(
        exception {
            $advertiser->p2p_advert_create(%params);
        },
        {
            error_code     => 'MaximumExceeded',
            message_params => [$maximum_advert, $params{account_currency}]
        },
        'Error when amount exceeds BO advert limit'
    );

    %params = %advert_params;
    my $maximum_order = BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_order;
    $params{max_order_amount} = $maximum_order + 1;
    cmp_deeply(
        exception {
            $advertiser->p2p_advert_create(%params);
        },
        {
            error_code     => 'MaxPerOrderExceeded',
            message_params => [$maximum_order, $params{account_currency}],
        },
        'Error when max_order_amount exceeds BO order limit'
    );

    %params = %advert_params;
    $params{min_order_amount} = $params{max_order_amount} + 1;
    cmp_deeply(
        exception {
            $advertiser->p2p_advert_create(%params);
        },
        {error_code => 'InvalidMinMaxAmount'},
        'Error when min_order_amount is more than max_order_amount'
    );

    %params = %advert_params;
    $params{amount} = $params{max_order_amount} - 1;
    cmp_deeply(
        exception {
            $advertiser->p2p_advert_create(%params);
        },
        {error_code => 'InvalidMaxAmount'},
        'Error when max_order_amount is more than amount'
    );

    %params = %advert_params;
    $params{type} = 'buy';
    cmp_deeply(
        exception {
            $advertiser->p2p_advert_create(%params);
        },
        {error_code => 'AdvertPaymentContactInfoNotAllowed'},
        'Error when payment/contact info provided for buy advert'
    );

    %params = %advert_params;
    $params{payment_info} = ' ';
    cmp_deeply(
        exception {
            $advertiser->p2p_advert_create(%params);
        },
        {error_code => 'AdvertPaymentInfoRequired'},
        'Error when payment info not provided for buy advert'
    );

    %params = %advert_params;
    $params{contact_info} = ' ';
    cmp_deeply(
        exception {
            $advertiser->p2p_advert_create(%params);
        },
        {error_code => 'AdvertContactInfoRequired'},
        'Error when contact info not provided for buy advert'
    );

    my $advert;
    %params = %advert_params;
    is(
        exception {
            $advert = $advertiser->p2p_advert_create(%params);
        },
        undef,
        "create advert successfully"
    );

    my $expected_advert = {
        account_currency         => uc($params{account_currency}),
        amount                   => num($params{amount}),
        amount_display           => num($params{amount}),
        country                  => $advertiser->residence,
        created_time             => re('\d+'),
        description              => $params{description},
        id                       => re('\d+'),
        is_active                => bool(1),
        local_currency           => $params{local_currency},
        max_order_amount         => num($params{max_order_amount}),
        max_order_amount_display => num($params{max_order_amount}),
        min_order_amount         => num($params{min_order_amount}),
        min_order_amount_display => num($params{min_order_amount}),
        payment_method           => $params{payment_method},
        payment_info             => $params{payment_info},
        contact_info             => $params{contact_info},
        price                    => num($params{rate}),
        price_display            => num($params{rate}),
        rate                     => num($params{rate}),
        rate_display             => num($params{rate}),
        remaining_amount         => num($params{amount}),
        remaining_amount_display => num($params{amount}),
        type                     => $params{type},
        counterparty_type        => $params{counterparty_type},
        advertiser_details       => {
            id              => $advertiser->p2p_advertiser_info->{id},
            name            => $name,
            completion_rate => undef,
        },
    };

    cmp_deeply($advert, $expected_advert, "advert_create returns expected fields");

    $expected_advert->{advertiser_details}{completion_rate} = undef;
    cmp_deeply($advertiser->p2p_advertiser_adverts, [$expected_advert], "p2p_advertiser_adverts returns expected fields");

    # these are not returned by previous calls because there was no counterparty to check balance for buy orders
    $expected_advert->{min_order_amount_limit} = $expected_advert->{min_order_amount_limit_display} = num($params{min_order_amount});
    $expected_advert->{max_order_amount_limit} = $expected_advert->{max_order_amount_limit_display} = num(2.4);    # advertiser balance

    cmp_deeply($advertiser->p2p_advert_info(id => $advert->{id}), $expected_advert, "advert_info returns expected fields");

    cmp_deeply($advertiser->p2p_advert_list, [$expected_advert], "p2p_advert_list returns expected fields");

    cmp_deeply($advertiser->p2p_advert_list(counterparty_type => 'buy'),
        [$expected_advert], "p2p_advert_list returns expected result when filtered by type");

    # Fields that should only be visible to advert owner
    delete @$expected_advert{
        qw( amount amount_display max_order_amount max_order_amount_display min_order_amount min_order_amount_display remaining_amount remaining_amount_display payment_info contact_info)
    };

    cmp_deeply($test_client_cr->p2p_advert_list, [$expected_advert], "p2p_advert_list returns less fields for client");

    cmp_deeply($test_client_cr->p2p_advert_info(id => $advert->{id}), $expected_advert, "advert_info returns less fields for client");

    cmp_deeply(
        exception {
            $test_client_cr->p2p_advertiser_adverts,
        },
        {error_code => 'AdvertiserNotRegistered'},
        "client gets error for p2p_advertiser_adverts"
    );

    cmp_ok $test_client_cr->p2p_advert_list(amount => 23)->[0]{price}, '==', $params{rate} * 23, 'Price is adjusted by amount param in advert list';
};

subtest 'Rate Validation' => sub {
    my %params     = %advert_params;
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();
    $advertiser->p2p_advertiser_update(name => 'testing');

    my $advert;

    $params{rate} = 0.0000001;
    cmp_deeply(
        exception {
            $advert = $advertiser->p2p_advert_create(%params);
        },
        {
            error_code     => 'RateTooSmall',
            message_params => ['0.000001'],
        },
        'Error when amount exceeds BO advert limit'
    );
    $params{rate} = 10**9 + 1;
    cmp_deeply(
        exception {
            $advert = $advertiser->p2p_advert_create(%params);
        },
        {
            error_code     => 'RateTooBig',
            message_params => ['1000000000.00'],
        },
        'Error when amount exceeds BO advert limit'
    );
};

subtest 'Duplicate ads' => sub {

    my %params = %advert_params;
    $params{rate}             = 50.0;
    $params{min_order_amount} = 5;
    $params{max_order_amount} = 9.99;

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(balance => 1000);

    BOM::Test::Helper::P2P::create_escrow;

    my $ad;
    lives_ok { $ad = $advertiser->p2p_advert_create(%params) } 'create first ad';

    subtest 'duplicate rate' => sub {

        cmp_deeply(
            exception {
                $advertiser->p2p_advert_create(%params)
            },
            {error_code => 'DuplicateAdvert'},
            'cannot create ad with duplicate rate'
        );

        $advertiser->p2p_advert_update(
            id        => $ad->{id},
            is_active => 0
        );
        lives_ok { $advertiser->p2p_advert_create(%params) } 'create duplicate ad when first disabled';

        cmp_deeply(
            exception {
                $advertiser->p2p_advert_update(
                    id        => $ad->{id},
                    is_active => 1
                )
            },
            {error_code => 'DuplicateAdvert'},
            'cannot enable ad with duplicate rate'
        );
    };

    subtest 'overlapping range' => sub {

        $params{rate}             = 49.99;
        $params{min_order_amount} = 9.99;
        $params{max_order_amount} = 19.99;

        cmp_deeply(
            exception {
                $advertiser->p2p_advert_create(%params)
            },
            {error_code => 'AdvertSameLimits'},
            'cannot create ad with overlapping min_order_amount'
        );

        $params{min_order_amount} = 1;
        $params{max_order_amount} = 5;
        cmp_deeply(
            exception {
                $advertiser->p2p_advert_create(%params)
            },
            {error_code => 'AdvertSameLimits'},
            'cannot create ad with overlapping max_order_amount'
        );

        $params{min_order_amount} = 6;
        $params{max_order_amount} = 7;
        cmp_deeply(
            exception {
                $advertiser->p2p_advert_create(%params)
            },
            {error_code => 'AdvertSameLimits'},
            'cannot create ad with inner range'
        );

        $params{min_order_amount} = 4;
        $params{max_order_amount} = 11;
        cmp_deeply(
            exception {
                $advertiser->p2p_advert_create(%params)
            },
            {error_code => 'AdvertSameLimits'},
            'cannot create ad with outer range'
        );

        $params{min_order_amount} = 10;
        $params{max_order_amount} = 19.99;
        lives_ok { $ad = $advertiser->p2p_advert_create(%params) } 'can create 2nd ad with new range';
        $advertiser->p2p_advert_update(
            id        => $ad->{id},
            is_active => 0
        );
        $params{rate} = 49.98;
        lives_ok { $advertiser->p2p_advert_create(%params) } 'can create again after disabling it';

        cmp_deeply(
            exception {
                $advertiser->p2p_advert_update(
                    id        => $ad->{id},
                    is_active => 1
                )
            },
            {error_code => 'AdvertSameLimits'},
            'cannot enable ad with overlapping range'
        );

        $params{rate}             = 49.95;
        $params{min_order_amount} = 20;
        $params{max_order_amount} = 29.99;
        lives_ok { $ad = $advertiser->p2p_advert_create(%params) } 'can create 3rd ad with new range';
    };

    subtest 'max ads of same type' => sub {

        BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_ads_per_type(3);
        $params{rate}             = 49.9;
        $params{min_order_amount} = 40;
        $params{max_order_amount} = 49;

        cmp_deeply(
            exception {
                $advertiser->p2p_advert_create(%params)
            },
            {
                error_code     => 'AdvertMaxExceededSameType',
                message_params => [3],
            },
            'limit for same ad type'
        );

        $advertiser->p2p_advert_update(
            id        => $ad->{id},
            is_active => 0
        );
        lives_ok { $advertiser->p2p_advert_create(%params) } 'can create after disabling another ad';

        cmp_deeply(
            exception {
                $advertiser->p2p_advert_update(
                    id        => $ad->{id},
                    is_active => 1
                )
            },
            {
                error_code     => 'AdvertMaxExceededSameType',
                message_params => [3],
            },
            'cannot enable ad which will exceed type limit'
        );

        $params{rate}             = 49.8;
        $params{min_order_amount} = 50;
        $params{max_order_amount} = 60;

        BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_ads_per_type(4);
        lives_ok { $advertiser->p2p_advert_create(%params) } 'can create 4th ad when limit increased';
        BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_ads_per_type(3);
    };

    subtest 'max active ads' => sub {
        for my $num (5 .. 10) {
            $params{local_currency} = chr($num + 60) x 3;
            lives_ok { $ad = $advertiser->p2p_advert_create(%params) } "can create ${num}th ad with different currency";
        }

        $params{local_currency} = 'xxx';
        cmp_deeply(
            exception {
                $advertiser->p2p_advert_create(%params)
            },
            {error_code => 'AdvertMaxExceeded'},
            'cannot have more than 10 active ads'
        );
        $advertiser->p2p_advert_update(
            id        => $ad->{id},
            is_active => 0
        );
        my $ad_10;
        lives_ok { $ad_10 = $advertiser->p2p_advert_create(%params) } 'can create after an ad is disabled';

        cmp_deeply(
            exception {
                $advertiser->p2p_advert_update(
                    id        => $ad->{id},
                    is_active => 1
                )
            },
            {error_code => 'AdvertMaxExceeded'},
            'cannot re-enable another ad'
        );

        BOM::Test::Helper::P2P::create_order(
            advert_id => $ad_10->{id},
            amount    => 55
        );
        lives_ok { $advertiser->p2p_advert_update(id => $ad->{id}, is_active => 1) } 'can re-enable if another ad is used up';
    };

    BOM::Test::Helper::P2P::reset_escrow;
};

subtest 'Updating advert' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        max_order_amount => 80,
        amount           => 100
    );
    ok $advert->{is_active}, 'advert is active';

    my $client = BOM::Test::Helper::P2P::create_advertiser();
    cmp_deeply(
        exception { $client->p2p_advert_update(id => $advert->{id}, is_listed => 0) },
        {error_code => 'PermissionDenied'},
        "Other client cannot edit advert"
    );

    ok !$advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 0
    )->{is_active}, "Deactivate advert";

    ok !$advertiser->p2p_advert_info(id => $advert->{id})->{is_active}, "advert is inactive";

    my $ad_info = $advertiser->p2p_advert_info(id => $advert->{id});

    # p2p_advert_update does not return these, because we don't know counterparty balance
    delete @$ad_info{qw( min_order_amount_limit min_order_amount_limit_display max_order_amount_limit max_order_amount_limit_display)};

    my $empty_update = $advertiser->p2p_advert_update(id => $advert->{id});
    cmp_deeply($empty_update, $ad_info, 'empty update returns all fields');

    my $real_update = $advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 1
    );
    $ad_info->{is_active} = 1;
    cmp_deeply($real_update, $ad_info, 'actual update returns all fields');
};

subtest 'Creating advert from non active advertiser' => sub {
    my %params     = %advert_params;
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();
    ok !$advertiser->p2p_advertiser_update(is_listed => 0)->{is_listed}, "set advertiser's adverts inactive";

    cmp_deeply(
        exception {
            $advertiser->p2p_advert_create(%params)
        },
        undef,
        "unlisted advertiser can still create advert"
    );
};

subtest 'Deleting ads' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert();
    BOM::Test::Helper::P2P::create_escrow();
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});

    for my $status (qw( pending buyer-confirmed timed-out )) {
        BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, $status);
        cmp_deeply(
            exception {
                $advertiser->p2p_advert_update(
                    id     => $advert->{id},
                    delete => 1
                )
            },
            {error_code => 'OpenOrdersDeleteAdvert'},
            "cannot delete ad with $status order"
        );
    }

    BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'cancelled');

    is exception { $advertiser->p2p_advert_update(id => $advert->{id}, delete => 1) }, undef, 'can delete ad with cancelled order';

    is $advertiser->p2p_advert_info(id => $advert->{id}), undef, 'deleted ad is not seen';

    cmp_deeply(
        exception {
            $client->p2p_order_create(
                advert_id => $advert->{id},
                amount    => 10
            )
        },
        {error_code => 'AdvertNotFound'},
        'cannot create order for deleted ad'
    );

    cmp_deeply(
        exception {
            $advertiser->p2p_advert_update(
                id     => $advert->{id},
                delete => 0,
            )
        },
        {error_code => 'AdvertNotFound'},
        'cannot undelete ad'
    );

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'p2p_advert_info' => sub {

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type             => 'buy',
        min_order_amount => 10,
        max_order_amount => 100
    );
    my $client = BOM::Test::Helper::P2P::create_advertiser(balance => 50);

    is $client->p2p_advert_info(id => -1), undef, 'non existant ad id returns undef';
    is $client->p2p_advert_info(), undef, 'missing id param returns undef';

    subtest 'use_client_limits' => sub {

        cmp_ok $client->p2p_advert_info(id => $advert->{id})->{max_order_amount_limit}, '==', 100, 'raw limit';
        cmp_ok $client->p2p_advert_info(
            id                => $advert->{id},
            use_client_limits => 1
        )->{max_order_amount_limit}, '==', 50, 'limit considers client balance';

        my $client2 = BOM::Test::Helper::P2P::create_advertiser();
        cmp_ok $client2->p2p_advert_info(
            id                => $advert->{id},
            use_client_limits => 1
        )->{max_order_amount_limit}, '==', 0, 'unorderable ad is returned';
    };
};

done_testing();
