use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Exception;
use Test::Deep;
use Test::MockModule;
use List::Util      qw(pairs);
use JSON::MaybeUTF8 qw(:v1);
use Date::Utility;

use BOM::User::Client;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::P2PWithClient;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Redis;
use BOM::Rules::Engine;
use P2P;

my $rule_engine = BOM::Rules::Engine->new();

BOM::Test::Helper::P2PWithClient::bypass_sendbird();
BOM::Test::Helper::P2PWithClient::create_payment_methods();

my $email = 'p2p_adverts_test@binary.com';

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;

$config->limits->maximum_advert(100);
$config->escrow([]);
$config->cancellation_barring->count(3);
$config->cancellation_barring->period(24);
$config->payment_methods_enabled(1);
$config->order_timeout(3600);

my $emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => sub { push $emitted_events->{$_[0]}->@*, $_[1] });

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
    payment_method    => 'bank_transfer',
    payment_info      => 'ad pay info',
    contact_info      => 'ad contact info',
    rate              => 1.23,
    rate_type         => 'fixed',
    type              => 'sell',
    counterparty_type => 'buy',
    block_trade       => 0,
);

# advert fields that should only be shown to the owner
my @sensitive_fields =
    qw(amount amount_display max_order_amount max_order_amount_display min_order_amount min_order_amount_display remaining_amount remaining_amount_display payment_info contact_info payment_method_ids active_orders payment_method_details visibility_status);

subtest 'Creating advert from non-advertiser' => sub {
    my %params = %advert_params;

    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('USD');
    cmp_deeply(
        exception { P2P->new(client => $client)->p2p_advert_create(%params) },
        {error_code => 'AdvertiserNotRegistered'},
        "non advertiser can't create advert"
    );
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
        buy_orders_amount     => num(0),
        cancel_time_avg       => undef,
        full_verification     => 0,
        release_time_avg      => undef,
        sell_completion_rate  => undef,
        sell_orders_count     => num(0),
        total_completion_rate => undef,
        total_orders_count    => num(0),
        sell_orders_amount    => num(0),
        show_name             => 0,
        balance_available     => num(0),
        withdrawal_limit      => num(10000),
        cancels_remaining     => 3,
        buy_time_avg          => undef,
        partner_count         => 0,
        total_turnover        => num(0),
        advert_rates          => undef,
        rating_average        => undef,
        rating_count          => 0,
        recommended_average   => undef,
        recommended_count     => undef,
        blocked_by_count      => 0,
        is_online             => 1,
        last_online_time      => num(time, 2),
        %params
    };

    my $advertiser_info = $adv_client->p2p_advertiser_info;
    cmp_deeply($advertiser_info, $expected, 'correct advertiser_info for advertiser');

    my $other_client = BOM::Test::Helper::P2PWithClient::create_advertiser();
    $advertiser_info = $other_client->p2p_advertiser_info(id => $adv->{id});
    delete $expected->@{
        qw/payment_info contact_info chat_user_id chat_token daily_buy daily_sell daily_buy_limit daily_sell_limit show_name balance_available cancels_remaining blocked_by_count withdrawal_limit/
    };
    $expected->{is_blocked}     = $expected->{is_favourite} = 0;
    $expected->{is_recommended} = undef;
    cmp_deeply($advertiser_info, $expected, 'sensitve fields hidden in advertiser_info for other client');
};

subtest 'Duplicate advertiser Registration' => sub {
    my $name       = 'ad man 2';
    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser(name => $name);

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
    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser();
    $advertiser->p2p_advertiser_update(is_approved => 0);
    delete $advertiser->{_p2p_advertiser_cached};

    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%advert_params)
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
    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser(%params);

    my $advertiser_info = $advertiser->p2p_advertiser_info;

    ok $advertiser_info->{is_approved}, 'advertiser is approved';
    is $advertiser_info->{name}, $params{name}, 'advertiser name';
    ok $advertiser_info->{is_listed}, 'advertiser is listed';
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
    delete $advertiser->{_p2p_advertiser_cached};

    is $advertiser->p2p_advertiser_update(name => 'test')->{name}, 'test', 'Do it again to ensure no duplicate error';

    ok !(
        $advertiser->p2p_advertiser_update(
            name      => 'test',
            is_listed => 0
        )->{is_listed}
        ),
        'Once more and switch flag is_listed to false';

    ok !($advertiser->p2p_advertiser_update(is_approved => 0)->{is_approved}), 'Disable approval';
    delete $advertiser->{_p2p_advertiser_cached};

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_update(is_listed => 1);
        },
        {error_code => 'AdvertiserNotApproved'},
        'Error when advertiser is not approved'
    );

    ok $advertiser->p2p_advertiser_update(is_approved => 1)->{is_approved}, 'Enabling approval';
    delete $advertiser->{_p2p_advertiser_cached};

    ok $advertiser->p2p_advertiser_update(is_listed => 1)->{is_listed}, 'Switch flag is_listed to true';
    delete $advertiser->{_p2p_advertiser_cached};

    for my $pair (pairs('default_advert_description', 'new desc', 'contact_info', 'new contact info', 'payment_info', 'new pay info')) {
        is $advertiser->p2p_advertiser_update($pair->[0] => $pair->[1])->{$pair->[0]}, $pair->[1], 'update ' . $pair->[0];
        delete $advertiser->{_p2p_advertiser_cached};
    }
};

subtest 'Creating advert' => sub {

    my $name       = 'ad man 4';
    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser(
        %advertiser_params,
        name    => $name,
        balance => 2.4
    );

    my %params         = %advert_params;
    my $maximum_advert = $config->limits->maximum_advert;
    $params{amount} = $maximum_advert + 1;

    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%params);
        },
        {
            error_code     => 'MaximumExceeded',
            message_params => [num($maximum_advert), $params{account_currency}]
        },
        'amount validation'
    );

    %params = %advert_params;
    $params{min_order_amount} = $params{max_order_amount} + 1;
    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%params);
        },
        {error_code => 'InvalidMinMaxAmount'},
        'min max validation'
    );

    %params = %advert_params;
    $params{rate} = 0.0000001;
    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%params);
        },
        {
            error_code     => 'RateTooSmall',
            message_params => ['0.000001'],
        },
        'rate validation'
    );

    %params = %advert_params;
    $params{contact_info} = ' ';
    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%params);
        },
        {error_code => 'AdvertContactInfoRequired'},
        'contact info validation'
    );

    %params = %advert_params;
    $params{payment_method} = ' ';
    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%params);
        },
        {error_code => 'AdvertPaymentMethodRequired'},
        'Error when payment method not provided for sell advert'
    );

    %params = %advert_params;
    $params{payment_info} = ' ';
    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%params);
        },
        {error_code => 'AdvertPaymentInfoRequired'},
        'Error when payment info not provided for sell advert'
    );

    %params                 = %advert_params;
    $params{payment_method} = ' ';
    $params{type}           = 'buy';
    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%params);
        },
        {error_code => 'AdvertPaymentMethodRequired'},
        'Error when payment method not provided for buy advert'
    );

    %params                     = %advert_params;
    $params{payment_method}     = 'x';
    $params{payment_method_ids} = [1, 2, 3];
    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%params);
        },
        {error_code => 'AdvertPaymentMethodParam'},
        'Error when both payment_method and payment_method_ids are provided for sell advert'
    );

    %params                       = %advert_params;
    $params{payment_method}       = 'x';
    $params{type}                 = 'buy';
    $params{payment_method_names} = ['x', 'y', 'z'];
    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%params);
        },
        {error_code => 'AdvertPaymentMethodParam'},
        'Error when both payment_method and payment_method_names are provided for buy advert'
    );

    %params                     = %advert_params;
    $params{payment_method}     = '';
    $params{payment_method_ids} = [1, 2, 3];
    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%params);
        },
        {error_code => 'InvalidPaymentMethods'},
        'payment_method_ids validation'
    );

    %params                       = %advert_params;
    $params{payment_method}       = '';
    $params{type}                 = 'buy';
    $params{payment_method_names} = ['x', 'y', 'z'];
    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%params);
        },
        {
            error_code     => 'InvalidPaymentMethod',
            message_params => subsetof('x', 'y', 'z'),
        },
        'payment_method_names validation'
    );

    undef $emitted_events;
    my $advert;
    %params = %advert_params;
    is(
        exception {
            $advert = P2P->new(client => $advertiser)->p2p_advert_create(%params);
        },
        undef,
        "create advert successfully"
    );

    my $expected_advert = {
        account_currency               => uc($params{account_currency}),
        amount                         => num($params{amount}),
        amount_display                 => num($params{amount}),
        country                        => $advertiser->residence,
        created_time                   => re('\d+'),
        description                    => $params{description},
        id                             => re('\d+'),
        is_active                      => bool(1),
        local_currency                 => uc($params{local_currency}),
        max_order_amount               => num($params{max_order_amount}),
        max_order_amount_display       => num($params{max_order_amount}),
        max_order_amount_limit         => num(2.4),                         # advertiser balance,
        max_order_amount_limit_display => num(2.4),
        min_order_amount               => num($params{min_order_amount}),
        min_order_amount_display       => num($params{min_order_amount}),
        min_order_amount_limit         => num($params{min_order_amount}),
        min_order_amount_limit_display => num($params{min_order_amount}),
        payment_method                 => $params{payment_method},
        payment_info                   => $params{payment_info},
        contact_info                   => $params{contact_info},
        price                          => num($params{rate}),
        price_display                  => num($params{rate}),
        rate                           => num($params{rate}),
        rate_display                   => num($params{rate}),
        remaining_amount               => num($params{amount}),
        remaining_amount_display       => num($params{amount}),
        type                           => $params{type},
        counterparty_type              => $params{counterparty_type},
        advertiser_details             => {
            id                     => $advertiser->p2p_advertiser_info->{id},
            name                   => $name,
            total_completion_rate  => undef,
            completed_orders_count => 0,
            rating_average         => undef,
            rating_count           => 0,
            recommended_average    => undef,
            recommended_count      => undef,
            is_online              => 1,
            last_online_time       => num(time, 2),
        },
        is_visible             => bool(1),
        active_orders          => 0,
        rate_type              => 'fixed',
        effective_rate         => num($params{rate}),
        effective_rate_display => num($params{rate}),
        rate_type              => $params{rate_type},
        order_expiry_period    => num(3600),
        block_trade            => 0,
    };

    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%params);
        },
        {error_code => 'DuplicateAdvert'},
        'Duplicate validation'
    );

    cmp_deeply($advert, $expected_advert, "advert_create returns expected fields");

    cmp_deeply(
        $emitted_events->{p2p_advert_created},
        [{
                loginid             => $advertiser->loginid,
                created_time        => Date::Utility->new($advert->{created_time})->datetime_yyyymmdd_hhmmss,
                advert_id           => $advert->{id},
                type                => $params{type},
                rate_type           => $params{rate_type},
                account_currency    => $params{account_currency},
                local_currency      => uc($params{local_currency}),
                country             => $advertiser->residence,
                amount              => num($params{amount}),
                rate                => num($params{rate}),
                min_order_amount    => num($params{min_order_amount}),
                max_order_amount    => num($params{max_order_amount}),
                is_visible          => bool(1),
                order_expiry_period => $expected_advert->{order_expiry_period},
            }
        ],
        'p2p_advert_created event fired'
    );

    cmp_deeply($advertiser->p2p_advertiser_adverts, [$expected_advert], "p2p_advertiser_adverts returns expected fields");

    cmp_deeply($advertiser->p2p_advert_info(id => $advert->{id}), $expected_advert, "advert_info returns expected fields");

    cmp_deeply($advertiser->p2p_advert_list, [$expected_advert], "p2p_advert_list returns expected fields");

    cmp_deeply($advertiser->p2p_advert_list(counterparty_type => 'buy'),
        [$expected_advert], "p2p_advert_list returns expected result when filtered by type");

    # Fields that should only be visible to advert owner
    delete $expected_advert->@{@sensitive_fields};
    $expected_advert->{advertiser_details}{is_blocked}     = $expected_advert->{advertiser_details}{is_favourite} = 0;
    $expected_advert->{advertiser_details}{is_recommended} = undef;
    $expected_advert->{is_eligible}                        = 1;

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

    lives_ok { $test_client_cr->p2p_advert_info(id => $advert->{id} . '.') } 'trailing period in id';
};

subtest 'Rate Validation' => sub {
    my %params     = %advert_params;
    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser();

    my $advert;

    $params{rate} = 0.0000001;
    cmp_deeply(
        exception {
            $advert = P2P->new(client => $advertiser)->p2p_advert_create(%params);
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
            $advert = P2P->new(client => $advertiser)->p2p_advert_create(%params);
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

    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser(balance => 1000);

    BOM::Test::Helper::P2PWithClient::create_escrow;

    my $ad;
    lives_ok { $ad = P2P->new(client => $advertiser)->p2p_advert_create(%params) } 'create first ad';

    subtest 'duplicate rate' => sub {

        cmp_deeply(
            exception {
                P2P->new(client => $advertiser)->p2p_advert_create(%params)
            },
            {error_code => 'DuplicateAdvert'},
            'cannot create ad with duplicate rate'
        );

        $advertiser->p2p_advert_update(
            id        => $ad->{id},
            is_active => 0
        );
        lives_ok { P2P->new(client => $advertiser)->p2p_advert_create(%params) } 'create duplicate ad when first disabled';

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
                P2P->new(client => $advertiser)->p2p_advert_create(%params)
            },
            {error_code => 'AdvertSameLimits'},
            'cannot create ad with overlapping min_order_amount'
        );

        $params{min_order_amount} = 1;
        $params{max_order_amount} = 5;
        cmp_deeply(
            exception {
                P2P->new(client => $advertiser)->p2p_advert_create(%params)
            },
            {error_code => 'AdvertSameLimits'},
            'cannot create ad with overlapping max_order_amount'
        );

        $params{min_order_amount} = 6;
        $params{max_order_amount} = 7;
        cmp_deeply(
            exception {
                P2P->new(client => $advertiser)->p2p_advert_create(%params)
            },
            {error_code => 'AdvertSameLimits'},
            'cannot create ad with inner range'
        );

        $params{min_order_amount} = 4;
        $params{max_order_amount} = 11;
        cmp_deeply(
            exception {
                P2P->new(client => $advertiser)->p2p_advert_create(%params)
            },
            {error_code => 'AdvertSameLimits'},
            'cannot create ad with outer range'
        );

        $params{min_order_amount} = 10;
        $params{max_order_amount} = 19.99;
        lives_ok { $ad = P2P->new(client => $advertiser)->p2p_advert_create(%params) } 'can create 2nd ad with new range';
        $advertiser->p2p_advert_update(
            id        => $ad->{id},
            is_active => 0
        );
        $params{rate} = 49.98;
        lives_ok { P2P->new(client => $advertiser)->p2p_advert_create(%params) } 'can create again after disabling it';

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
        lives_ok { $ad = P2P->new(client => $advertiser)->p2p_advert_create(%params) } 'can create 3rd ad with new range';
    };

    subtest 'max ads of same type' => sub {

        BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_ads_per_type(3);
        $params{rate}             = 49.9;
        $params{min_order_amount} = 40;
        $params{max_order_amount} = 49;

        cmp_deeply(
            exception {
                P2P->new(client => $advertiser)->p2p_advert_create(%params)
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
        lives_ok { P2P->new(client => $advertiser)->p2p_advert_create(%params) } 'can create after disabling another ad';

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
        lives_ok { P2P->new(client => $advertiser)->p2p_advert_create(%params) } 'can create 4th ad when limit increased';
        BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_ads_per_type(3);
    };

    subtest 'max active ads' => sub {
        for my $num (5 .. 10) {
            $params{local_currency} = chr($num + 60) x 3;
            lives_ok { $ad = P2P->new(client => $advertiser)->p2p_advert_create(%params) } "can create ${num}th ad with different currency";
        }

        $params{local_currency} = 'xxx';
        cmp_deeply(
            exception {
                P2P->new(client => $advertiser)->p2p_advert_create(%params)
            },
            {error_code => 'AdvertMaxExceeded'},
            'cannot have more than 10 active ads'
        );
        $advertiser->p2p_advert_update(
            id        => $ad->{id},
            is_active => 0
        );
        my $ad_10;
        lives_ok { $ad_10 = P2P->new(client => $advertiser)->p2p_advert_create(%params) } 'can create after an ad is disabled';

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

        BOM::Test::Helper::P2PWithClient::create_order(
            advert_id => $ad_10->{id},
            amount    => 55
        );
        lives_ok { $advertiser->p2p_advert_update(id => $ad->{id}, is_active => 1) } 'can re-enable if another ad is used up';
    };

    BOM::Test::Helper::P2PWithClient::reset_escrow;
};

subtest 'Updating advert' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2PWithClient::create_advert(
        max_order_amount => 80,
        amount           => 100
    );
    ok $advert->{is_active}, 'advert is active';

    my $client = BOM::Test::Helper::P2PWithClient::create_advertiser();
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

    undef $emitted_events;
    my $empty_update = $advertiser->p2p_advert_update(id => $advert->{id});
    cmp_deeply($empty_update, $ad_info, 'empty update returns all fields');
    ok !$emitted_events, 'no events emitted for empty update';

    my $real_update = $advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 1
    );
    $ad_info->{is_active} = $ad_info->{is_visible} = 1;
    delete $ad_info->{visibility_status};
    cmp_deeply($real_update, $ad_info, 'actual update returns all fields');
};

subtest 'Creating advert from non active advertiser' => sub {
    my %params     = %advert_params;
    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser();
    ok !$advertiser->p2p_advertiser_update(is_listed => 0)->{is_listed}, "set advertiser's adverts inactive";
    delete $advertiser->{_p2p_advertiser_cached};

    cmp_deeply(
        exception {
            P2P->new(client => $advertiser)->p2p_advert_create(%params)
        },
        undef,
        "unlisted advertiser can still create advert"
    );
};

subtest 'Deleting ads' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2PWithClient::create_advert();
    BOM::Test::Helper::P2PWithClient::create_escrow();
    my ($client, $order) = BOM::Test::Helper::P2PWithClient::create_order(advert_id => $advert->{id});

    for my $status (qw( pending buyer-confirmed timed-out )) {
        BOM::Test::Helper::P2PWithClient::set_order_status($client, $order->{id}, $status);
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

    BOM::Test::Helper::P2PWithClient::set_order_status($client, $order->{id}, 'cancelled');

    my $resp;
    is exception { $resp = $advertiser->p2p_advert_update(id => $advert->{id}, delete => 1) }, undef, 'can delete ad with cancelled order';
    cmp_deeply $resp,
        {
        id      => $advert->{id},
        deleted => 1
        },
        'response for deleted ad';

    is $advertiser->p2p_advert_info(id => $advert->{id}), undef, 'deleted ad is not seen';

    cmp_deeply(
        exception {
            $client->p2p_order_create(
                advert_id   => $advert->{id},
                amount      => 10,
                rule_engine => $rule_engine,
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

    BOM::Test::Helper::P2PWithClient::reset_escrow();
};

subtest 'p2p_advert_info' => sub {

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type             => 'buy',
        min_order_amount => 10,
        max_order_amount => 100
    );
    my $client = BOM::Test::Helper::P2PWithClient::create_advertiser(balance => 50);

    is $client->p2p_advert_info(id => -1), undef, 'non existant ad id returns undef';
    is $client->p2p_advert_info(),         undef, 'missing id param returns undef';

    subtest 'use_client_limits' => sub {

        cmp_ok $client->p2p_advert_info(id => $advert->{id})->{max_order_amount_limit}, '==', 100, 'raw limit';
        cmp_ok $client->p2p_advert_info(
            id                => $advert->{id},
            use_client_limits => 1
        )->{max_order_amount_limit}, '==', 50, 'limit considers client balance';

        my $client2 = BOM::Test::Helper::P2PWithClient::create_advertiser();
        cmp_ok $client2->p2p_advert_info(
            id                => $advert->{id},
            use_client_limits => 1
        )->{max_order_amount_limit}, '==', 0, 'unorderable ad is returned';
    };
};

subtest 'is_visible flag and subscription event' => sub {

    my %ad_params = (
        type             => 'sell',
        amount           => 100,
        description      => 'test advert',
        local_currency   => 'myr',
        rate             => 1,
        rate_type        => 'fixed',
        max_order_amount => 10,
        min_order_amount => 2,
        payment_method   => 'bank_transfer',
        payment_info     => 'x',
        contact_info     => 'x',
    );

    my $client        = BOM::Test::Helper::P2PWithClient::create_advertiser(balance => 1);
    my $advertiser_id = $client->_p2p_advertiser_cached->{id};

    undef $emitted_events;
    my $advert = P2P->new(client => $client)->p2p_advert_create(%ad_params);

    cmp_deeply($emitted_events->{p2p_adverts_updated}, [{advertiser_id => $advertiser_id}], 'p2p_adverts_updated event emitted for advert create');

    cmp_ok $advert->{is_visible}, '==', 0, 'not visible due to low balance';
    cmp_deeply $advert->{visibility_status}, ['advertiser_balance'], 'visibility_status contains advertiser_balance';
    BOM::Test::Helper::Client::top_up($client, $client->currency, 9);

    $advert = $client->p2p_advert_info(id => $advert->{id});
    cmp_ok $advert->{is_visible}, '==', 1, 'visible after top up';
    ok !exists $advert->{visibility_status}, 'visibility_status absent for visible ad';

    $client->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET blocked_until=NOW() + INTERVAL '1 hour' WHERE id = $advertiser_id");
    $advert = $client->p2p_advert_info(id => $advert->{id});
    cmp_ok $advert->{is_visible}, '==', 0, 'not visible due to temp block';
    cmp_deeply $advert->{visibility_status}, ['advertiser_temp_ban'], 'visibility_status contains advertiser_temp_ban';
    $client->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET blocked_until=NULL WHERE id = $advertiser_id");
    cmp_ok $client->p2p_advert_info(id => $advert->{id})->{is_visible}, '==', 1, 'visible after temp block removed';

    $client->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET is_approved=FALSE WHERE id = $advertiser_id");
    $advert = $client->p2p_advert_info(id => $advert->{id});
    cmp_ok $advert->{is_visible}, '==', 0, 'not visible when not approved';
    cmp_deeply $advert->{visibility_status}, ['advertiser_approval'], 'visibility_status contains advertiser_approval';
    $client->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET is_approved=TRUE WHERE id = $advertiser_id");
    cmp_ok $client->p2p_advert_info(id => $advert->{id})->{is_visible}, '==', 1, 'visible after approved';

    $client->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET is_listed=FALSE WHERE id = $advertiser_id");
    $advert = $client->p2p_advert_info(id => $advert->{id});
    cmp_ok $advert->{is_visible}, '==', 0, 'not visible when not listed';
    cmp_deeply $advert->{visibility_status}, ['advertiser_ads_paused'], 'visibility_status contains advertiser_ads_paused';
    $client->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET is_listed=TRUE WHERE id = $advertiser_id");
    cmp_ok $client->p2p_advert_info(id => $advert->{id})->{is_visible}, '==', 1, 'visible after listed';

    $config->limits->maximum_order(1);
    $advert = $client->p2p_advert_info(id => $advert->{id});
    cmp_ok $advert->{is_visible}, '==', 0, 'not visible when global order limit exceeded';
    cmp_deeply $advert->{visibility_status}, ['advert_max_limit'], 'visibility_status contains advert_max_limit';
    $config->limits->maximum_order(1000);
    cmp_ok $client->p2p_advert_info(id => $advert->{id})->{is_visible}, '==', 1, 'visible after limit increased';

    my $client2 = BOM::Test::Helper::P2PWithClient::create_advertiser;
    $client2->p2p_advertiser_relations(add_blocked => [$advertiser_id]);
    cmp_ok $client2->p2p_advert_info(id => $advert->{id})->{is_visible}, '==', 0, 'not visible when blocked';
    $client2->p2p_advertiser_relations(remove_blocked => [$advertiser_id]);
    cmp_ok $client2->p2p_advert_info(id => $advert->{id})->{is_visible}, '==', 1, 'visible after unblocked';

    undef $emitted_events;
    $advert = $client->p2p_advert_update(
        id        => $advert->{id},
        is_active => 0
    );

    cmp_deeply($emitted_events->{p2p_adverts_updated}, [{advertiser_id => $advertiser_id}], 'p2p_adverts_updated event emitted for advert update');
    cmp_ok $advert->{is_visible}, '==', 0, 'not visible after deactivate';
    cmp_deeply $advert->{visibility_status}, ['advert_inactive'], 'visibility_status contains advert_inactive';

    cmp_ok $client->p2p_advert_update(
        id        => $advert->{id},
        is_active => 1
    )->{is_visible}, '==', 1, 'visible after activate';

    $advert = $client->p2p_advert_update(
        id               => $advert->{id},
        remaining_amount => 0
    );

    cmp_ok $advert->{is_visible}, '==', 0, 'not visible after setting remaining to zero';
    cmp_deeply $advert->{visibility_status}, ['advert_remaining'], 'visibility_status contains advert_remaining';

    cmp_ok $client->p2p_advert_update(
        id               => $advert->{id},
        remaining_amount => 100
    )->{is_visible}, '==', 1, 'visible after increasing remaining';

    my $client3 = BOM::Test::Helper::P2PWithClient::create_advertiser(
        balance        => 100,
        currency       => 'USD',
        client_details => {residence => 'zw'},
    );
    $advertiser_id = $client3->p2p_advertiser_info->{id};

    $client3->db->dbic->dbh->do(
        "INSERT INTO p2p.p2p_country_trade_band (country, trade_band, currency, max_daily_buy, max_daily_sell, min_balance)
        VALUES ('zw','low','USD',100,100,11), ('zw','medium','USD',100,100,NULL)"
    );

    $advert = P2P->new(client => $client3)->p2p_advert_create(%ad_params);

    cmp_ok $advert->{is_visible}, '==', 0, 'not visible when balance below band min';
    cmp_deeply $advert->{visibility_status}, ['advert_min_limit'], 'visibility_status contains advert_min_limit';
    $client3->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET trade_band = 'medium' WHERE id = ?", undef, $advertiser_id);
    cmp_ok $client3->p2p_advert_info(id => $advert->{id})->{is_visible}, '==', 1, 'visible after changing band';

    $client3->db->dbic->dbh->do('INSERT INTO p2p.p2p_advertiser_totals_daily (advertiser_id, day, sell_amount) VALUES (?, NOW(), 100)',
        undef, $advertiser_id);
    $advert = $client3->p2p_advert_info(id => $advert->{id});
    cmp_ok $advert->{is_visible}, '==', 0, 'not visible when sell limit exceeded';
    cmp_deeply $advert->{visibility_status}, ['advertiser_daily_limit'], 'visibility_status contains advertiser_daily_limit';

    $client3->db->dbic->dbh->do('DELETE FROM p2p.p2p_advertiser_totals_daily');
    cmp_ok $client3->p2p_advert_info(id => $advert->{id})->{is_visible}, '==', 1, 'visible after turnover reset';

    $client3->db->dbic->dbh->do('INSERT INTO p2p.p2p_advertiser_totals_daily (advertiser_id, day, buy_amount) VALUES (?, NOW(), 100)',
        undef, $advertiser_id);

    $advert = P2P->new(client => $client3)->p2p_advert_create(
        type             => 'buy',
        amount           => 100,
        min_order_amount => 1,
        max_order_amount => 10,
        rate             => 1,
        rate_type        => 'fixed',
        payment_method   => 'bank_transfer',
    );

    $advert = $client3->p2p_advert_info(id => $advert->{id});
    cmp_ok $advert->{is_visible}, '==', 0, 'not visible when buy limit exceeded';
    cmp_deeply $advert->{visibility_status}, ['advertiser_daily_limit'], 'visibility_status contains advertiser_daily_limit';

    $client3->db->dbic->dbh->do('DELETE FROM p2p.p2p_advertiser_totals_daily');
    cmp_ok $client3->p2p_advert_info(id => $advert->{id})->{is_visible}, '==', 1, 'visible after turnover reset';
};

subtest 'subscriptions' => sub {
    my $redis   = BOM::Config::Redis->redis_p2p_write;
    my $client1 = BOM::Test::Helper::Client::create_client();
    $client1->account('USD');

    cmp_deeply(
        exception { $client1->p2p_advert_info(subscribe => 1) },
        {error_code => 'AdvertiserNotRegistered'},
        'must be advertiser to subscribe all'
    );

    my $advertiser_id = $client1->p2p_advertiser_create(name => 'x')->{id};
    $client1->status->set('age_verification', 'system', 'x');
    my $key = 'P2P::ADVERT_STATE::' . $advertiser_id;
    $redis->del($key);
    my $expected_response = {
        advertiser_id         => $advertiser_id,
        advertiser_account_id => $client1->account->id
    };

    cmp_deeply($client1->p2p_advert_info(subscribe => 1), $expected_response, 'response when subscribe to all with no ads');

    cmp_deeply decode_json_utf8($redis->get($key)), {}, 'no ads, no state saved in redis';

    my $pms = $client1->p2p_advertiser_payment_methods(create => [{method => 'method1'}, {method => 'method2'}]);
    $client1->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET is_approved=TRUE WHERE id = $advertiser_id");

    delete $client1->{_p2p_advertiser_cached};
    my $advert = (
        BOM::Test::Helper::P2P::create_advert(
            client             => P2P->new(client => $client1),
            type               => 'sell',
            payment_method     => '',
            payment_method_ids => [keys %$pms]))[1];

    cmp_deeply($client1->p2p_advert_info(subscribe => 1), $expected_response, 'response when subscribe to all with an ad');

    my $state = decode_json_utf8($redis->get($key));

    cmp_deeply [keys %$state], [$advert->{id}], 'state saved';
    cmp_set [keys $state->{$advert->{id}}{active_orders}->%*], [$client1->loginid], 'client specific state saved';

    my $client2 = BOM::Test::Helper::Client::create_client();
    $client2->account('USD');

    my $resp = $client2->p2p_advert_info(
        id        => $advert->{id},
        subscribe => 1
    );

    delete $advert->@{@sensitive_fields};
    $advert->{advertiser_details}{is_blocked}     = $advert->{advertiser_details}{is_favourite} = 0;
    $advert->{advertiser_details}{is_recommended} = undef;
    $advert->{is_eligible}                        = 1;

    cmp_deeply($resp, {%$advert, %$expected_response}, 'response for other client subscribing to ad');

    $state = decode_json_utf8($redis->get($key));
    cmp_set [keys $state->{$advert->{id}}{active_orders}->%*], [$client1->loginid, $client2->loginid], 'client specific state saved';
};

subtest 'rate check' => sub {
    BOM::Test::Helper::P2PWithClient::create_escrow();

    my (undef, $advert) = BOM::Test::Helper::P2P::create_advert(
        rate => 1.001,
    );

    my $client = BOM::Test::Helper::P2PWithClient::create_advertiser;

    cmp_deeply(
        exception {
            $client->p2p_order_create(
                advert_id   => $advert->{id},
                amount      => 10,
                rate        => 1.00200,
                rule_engine => $rule_engine,
            )
        },
        {error_code => 'OrderCreateFailRateChanged'},
        'error if different rate provided'
    );

    is(
        exception {
            $client->p2p_order_create(
                advert_id   => $advert->{id},
                amount      => 10,
                rate        => 1.00100,
                rule_engine => $rule_engine,
            )
        },
        undef,
        'can create order with correct rate'
    );

    BOM::Test::Helper::P2PWithClient::reset_escrow();
};

subtest 'Creating advert with custom order_expiry_period values' => sub {
    BOM::Test::Helper::P2PWithClient::create_escrow();
    for my $order_expiry_period (900, 1800, 2700, 3600, 5400, 7200) {
        my ($advert, $order);
        cmp_deeply(
            exception {
                (undef, $advert) = BOM::Test::Helper::P2P::create_advert(order_expiry_period => $order_expiry_period);
            },
            undef,
            "create advert successfully"
        );
        undef $emitted_events;
        is $advert->{order_expiry_period}, $order_expiry_period, 'expected order_expiry_period for ad';
        (undef, $order) = BOM::Test::Helper::P2PWithClient::create_order(advert_id => $advert->{id});
        is $order->{expiry_time}, ($order->{created_time} + $advert->{order_expiry_period}), "order expiry epoch reflected correctly";
    }

    cmp_deeply(
        exception {
            BOM::Test::Helper::P2P::create_advert(order_expiry_period => $_)
        },
        {error_code => 'InvalidOrderExpiryPeriod'},
        'invalid order expiry time error captured correctly'
    ) foreach (100, 200.15, "900.00", "abc");

    BOM::Test::Helper::P2PWithClient::reset_escrow();

};

done_testing();
