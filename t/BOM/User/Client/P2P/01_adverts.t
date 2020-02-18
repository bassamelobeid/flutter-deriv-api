use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;

use BOM::User::Client;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

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

my $advertiser_name = 'advertiser name';

my %advert_params = (
    account_currency  => 'usd',
    amount            => 100,
    country           => 'ID',
    description       => 'test advert',
    local_currency    => 'myr',
    max_order_amount  => 10,
    min_order_amount  => 0.1,
    payment_method    => 'camels',
    rate              => 1.23,
    type              => 'buy',
    counterparty_type => 'sell',
);

my %params = %advert_params;

subtest 'Creating advert from non-advertiser' => sub {
    my %params = %advert_params;

    my $client = BOM::Test::Helper::P2P::create_client();
    cmp_deeply(exception { $client->p2p_advert_create(%params) }, {error_code => 'AdvertiserNotRegistered'}, "non advertiser can't create advert");
};

subtest 'advertiser Registration' => sub {
    my $client = BOM::Test::Helper::P2P::create_client();
    cmp_ok $client->p2p_advertiser_create($advertiser_name)->{client_loginid}, 'eq', $client->loginid, "create advertiser";
    my $advertiser_info = $client->p2p_advertiser_info;
    ok !$advertiser_info->{is_approved}, "advertiser not approved";
    ok $advertiser_info->{is_listed}, "advertiser adverts are listed";
    cmp_ok $advertiser_info->{name}, 'eq', $advertiser_name, "advertiser name";
};

subtest 'Duplicate advertiser Registration' => sub {
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_create($advertiser_name)
        },
        {error_code => 'AlreadyRegistered'},
        "duplicate advertiser request not allowed"
    );
};

subtest 'Creating advert from not approved advertiser' => sub {
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();
    $advertiser->p2p_advertiser_update(is_approved => 0);

    cmp_deeply(
        exception {
            $advertiser->p2p_advert_create(%params)
        },
        {error_code => 'AdvertiserNotApproved'},
        "non approved can't create advert"
    );
};

subtest 'Updating advertiser fields' => sub {
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(name => $advertiser_name);

    my $advertiser_info = $advertiser->p2p_advertiser_info;

    ok $advertiser_info->{is_approved}, 'advertiser is approved';
    is $advertiser_info->{name},        $advertiser_name, 'advertiser name';
    ok $advertiser_info->{is_listed},   'advertiser is listed';

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_update(name => ' ');
        },
        {error_code => 'AdvertiserNameRequired'},
        'Error when advertiser name is blank'
    );

    is $advertiser->p2p_advertiser_update(name => 'test')->{name}, 'test', 'Changing name';

    ok !($advertiser->p2p_advertiser_update(is_listed => 0)->{is_listed}), 'Switch flag is_listed to false';

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
};

subtest 'Creating advert' => sub {
    my %params = %advert_params;
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(name => $advertiser_name);
    $advertiser->p2p_advertiser_update(name => $advertiser_name);

    my $advert;

    for my $numeric_field (qw(amount max_order_amount min_order_amount rate)) {
        %params = %advert_params;

        $params{$numeric_field} = -1;
        cmp_deeply(
            exception {
                $advert = $advertiser->p2p_advert_create(%params);
            },
            {
                error_code => 'InvalidNumericValue',
                details    => {fields => [$numeric_field]},
            },
            "Error when numeric field '$numeric_field' is not greater than 0"
        );
    }

    %params = %advert_params;
    $params{amount} = 200;
    cmp_deeply(
        exception {
            $advert = $advertiser->p2p_advert_create(%params);
        },
        {error_code => 'MaximumExceeded'},
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
            message_params => [uc $params{account_currency}, $maximum_order],
        },
        'Error when max_order_amount exceeds BO order limit'
    );

    %params = %advert_params;
    $params{min_order_amount} = $params{max_order_amount} + 1;
    cmp_deeply(
        exception {
            $advert = $advertiser->p2p_advert_create(%params);
        },
        {error_code => 'InvalidMinMaxAmount'},
        'Error when min_order_amount is more than max_order_amount'
    );

    %params = %advert_params;
    $params{amount} = $params{max_order_amount} - 1;
    cmp_deeply(
        exception {
            $advert = $advertiser->p2p_advert_create(%params);
        },
        {error_code => 'InvalidMaxAmount'},
        'Error when max_order_amount is more than amount'
    );

    %params = %advert_params;
    is(
        exception {
            $advert = $advertiser->p2p_advert_create(%params);
        },
        undef,
        "create advert successfully"
    );

    my $expected_advert = {
        account_currency               => uc($params{account_currency}),
        amount                         => num($params{amount}),
        amount_display                 => num($params{amount}),
        country                        => $params{country},
        created_time                   => re('\d+'),
        description                    => $params{description},
        id                             => re('\d+'),
        is_active                      => bool(1),
        local_currency                 => $params{local_currency},
        max_order_amount               => num($params{max_order_amount}),
        max_order_amount_display       => num($params{max_order_amount}),
        max_order_amount_limit         => num($params{max_order_amount}),
        max_order_amount_limit_display => num($params{max_order_amount}),
        min_order_amount               => num($params{min_order_amount}),
        min_order_amount_display       => num($params{min_order_amount}),
        min_order_amount_limit         => num($params{min_order_amount}),
        min_order_amount_limit_display => num($params{min_order_amount}),
        payment_method                 => $params{payment_method},
        price                          => num($params{rate}),
        price_display                  => num($params{rate}),
        rate                           => num($params{rate}),
        rate_display                   => num($params{rate}),
        remaining_amount               => num($params{amount}),
        remaining_amount_display       => num($params{amount}),
        type                           => $params{type},
        counterparty_type              => $params{counterparty_type},
        advertiser_details             => {
            id   => $advertiser->p2p_advertiser_info->{id},
            name => $advertiser_name,
        },
    };

    cmp_deeply($advert, $expected_advert, "advert_create returns expected fields");

    cmp_deeply($advertiser->p2p_advert_info(id => $advert->{id}), $expected_advert, "advert_info returns expected fields");

    cmp_deeply($advertiser->p2p_advert_list, [$expected_advert], "p2p_advert_list returns expected fields");

    cmp_deeply($advertiser->p2p_advert_list(counterparty_type => $BOM::User::Client::P2P_COUNTERYPARTY_TYPE_MAPPING->{$params{type}}),
        [$expected_advert], "p2p_advert_list returns expected result when filtered by type");

    cmp_deeply($advertiser->p2p_advertiser_adverts, [$expected_advert], "p2p_advertiser_adverts returns expected fields");

    # Fields that should only be visible to advert owner
    delete @$expected_advert{
        qw( amount amount_display max_order_amount max_order_amount_display min_order_amount min_order_amount_display remaining_amount remaining_amount_display)
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

subtest 'Updating advert' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        max_order_amount => 80,
        amount           => 100
    );
    ok $advert->{is_active}, 'advert is active';

    my $client = BOM::Test::Helper::P2P::create_client();
    cmp_deeply(
        exception { $client->p2p_advert_update(id => $advert->{id}, is_active => 0) },
        {error_code => 'PermissionDenied'},
        "Other client cannot edit advert"
    );

    ok !$advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 0
    )->{is_active}, "Deactivate advert";

    ok !$advertiser->p2p_advert_info(id => $advert->{id})->{is_active}, "advert is inactive";

    ok $advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 1
    )->{is_active}, "reactivate advert";

    my $empty_update = $advertiser->p2p_advert_update(id => $advert->{id});
    cmp_deeply($empty_update, $advertiser->p2p_advert_info(id => $advert->{id}), 'empty update');
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

done_testing();
