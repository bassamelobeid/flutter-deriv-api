use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;

use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Runtime;
use JSON::MaybeUTF8 qw(:v1);

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();
BOM::Test::Helper::P2P::create_payment_methods();
BOM::Test::Helper::P2P::populate_trade_band_db();

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$config->payment_methods_enabled(1);
$config->block_trade->enabled(1);
$config->restricted_countries([]);

my %params = (
    is_active        => 1,
    account_currency => 'USD',
    local_currency   => 'IDR',
    amount           => 100,
    description      => 'test advert',
    max_order_amount => 20,
    min_order_amount => 5,
    payment_method   => 'bank_transfer',
    payment_info     => 'ad pay info',
    contact_info     => 'ad contact info',
    rate             => 1.0,
    rate_type        => 'fixed',
    type             => 'sell',
    country          => 'id',
    block_trade      => 0,
);

my $method = '_validate_advert';
subtest $method => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();

    is(
        exception {
            $advertiser->$method(%params);
        },
        undef,
        'no error for valid params'
    );
};

$method = '_validate_advert_amount';
subtest $method => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(balance => 100);
    my $max_ad     = $config->limits->maximum_advert;

    is(
        exception {
            $advertiser->$method(%params, amount => $max_ad);
        },
        undef,
        'no error at the max'
    );

    cmp_deeply(
        exception {
            $advertiser->$method(%params, amount => $max_ad + 1);
        },
        {
            error_code     => 'MaximumExceeded',
            message_params => [num($max_ad), $params{account_currency}]
        },
        'Error when amount exceeds BO advert limit'
    );

    my $ad = $advertiser->p2p_advert_create(%params);

    is(
        exception {
            $advertiser->$method(
                %params,
                amount => $max_ad + 1,
                id     => $ad->{id},
            );
        },
        undef,
        'no error for edit ad'
    );

    my $order1 = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad->{id},
        amount    => 10
    );

    my $order2 = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad->{id},
        amount    => 10
    );

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                remaining_amount => $max_ad - 15,
                id               => $ad->{id},
            );
        },
        {
            error_code     => 'MaximumExceededNewAmount',
            message_params => [num($max_ad), num(20), num($max_ad - 15 + 20), $params{account_currency}]
        },
        'Error with open orders'
    );

    BOM::Test::Helper::P2P::set_order_status($advertiser, $order1->{id}, 'completed');

    is exception {
        $advertiser->$method(
            %params,
            remaining_amount => $max_ad - 15,
            id               => $ad->{id},
        );
    }
    ->{error_code}, 'MaximumExceededNewAmount', 'still get error after order completed';

    BOM::Test::Helper::P2P::set_order_status($advertiser, $order2->{id}, 'refunded');

    is(
        exception {
            $advertiser->$method(
                %params,
                remaining_amount => $max_ad - 15,
                id               => $ad->{id},
            );
        },
        undef,
        'no error after an order is refunded/cancelled'
    );

    $config->block_trade->maximum_advert(10000);

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                amount      => 10001,
                block_trade => 1,
            );
        },
        {
            error_code     => 'MaximumExceeded',
            message_params => ['10000.00', 'USD']
        },
        'Error for excessive block trade ad amount'
    );

    is(
        exception {
            $advertiser->$method(
                %params,
                amount      => 10000,
                block_trade => 1,
            );
        },
        undef,
        'No error for block trade amount within limit'
    );
};

$method = '_validate_advert_min_max';
subtest $method => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();
    $advertiser->db->dbic->dbh->do(
        "UPDATE p2p.p2p_advertiser SET trade_band = 'block_trade_medium' WHERE id = " . $advertiser->p2p_advertiser_info->{id});
    delete $advertiser->{_p2p_advertiser_cached};
    # limits are: normal = 5 - 500, block trade = 1000 to 10000

    cmp_deeply(
        exception {
            $advertiser->$method(%params, min_order_amount => 1);
        },
        {
            error_code     => 'BelowPerOrderLimit',
            message_params => ['5.00', 'USD']
        },
        'min_order_amount below band min order'
    );

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                block_trade      => 1,
                min_order_amount => 999
            );
        },
        {
            error_code     => 'BelowPerOrderLimit',
            message_params => ['1000.00', 'USD']
        },
        'min_order_amount below block trade band min order'
    );

    $config->limits->maximum_order(100);

    cmp_deeply(
        exception {
            $advertiser->$method(%params, max_order_amount => 101);
        },
        {
            error_code     => 'MaxPerOrderExceeded',
            message_params => ['100.00', 'USD'],
        },
        'Error when max_order_amount exceeds BO order limit'
    );

    $config->limits->maximum_order(3000);

    cmp_deeply(
        exception {
            $advertiser->$method(%params, max_order_amount => 501);
        },
        {
            error_code     => 'MaxPerOrderExceeded',
            message_params => ['500.00', 'USD'],
        },
        'Error when max_order_amount exceeds band max order'
    );

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                block_trade      => 1,
                min_order_amount => 1000,
                max_order_amount => 10001
            );
        },
        {
            error_code     => 'MaxPerOrderExceeded',
            message_params => ['10000.00', 'USD'],
        },
        'Error when max_order_amount exceeds band block trade max order'
    );

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                min_order_amount => 5,
                max_order_amount => 4
            );
        },
        {error_code => 'InvalidMinMaxAmount'},
        'Error when min_order_amount is more than max_order_amount'
    );

    $advertiser = BOM::Test::Helper::P2P::create_advertiser();    # to get default band

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                rate             => 0.0001,
                min_order_amount => 1
            );
        },
        {
            error_code     => 'MinPriceTooSmall',
            message_params => [0]
        },
        'Error when min order in local currency rounds to zero'
    );
};

$method = '_validate_advert_rates';
subtest $method => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(client_details => {residence => 'id'});
    my %params     = %params;

    $config->country_advert_config(
        encode_json_utf8({
                'id' => {
                    float_ads => 'enabled',
                    fixed_ads => 'disabled'
                }}));

    subtest 'fixed rate' => sub {
        $params{rate_type} = 'fixed';

        cmp_deeply(
            exception {
                $advertiser->$method(%params, rate => 1);
            },
            {
                error_code => 'AdvertFixedRateNotAllowed',
            },
            'Error when fixed rate disabled'
        );

        is(
            exception {
                $advertiser->$method(
                    %params,
                    rate      => 1.23,
                    is_active => 0,
                    old       => {rate_type => 'fixed'});
            },
            undef,
            'No error editing fixed ad when fixed ads disabled'
        );

        $config->country_advert_config(
            encode_json_utf8({
                    'id' => {
                        float_ads => 'disabled',
                        fixed_ads => 'enabled'
                    }}));

        cmp_deeply(
            exception {
                $advertiser->$method(%params, rate => 0.0000001);
            },
            {
                error_code     => 'RateTooSmall',
                message_params => ['0.000001'],
            },
            'Error when rate is too small'
        );

        cmp_deeply(
            exception {
                $advertiser->$method(%params, rate => 10**9 + 1);
            },
            {
                error_code     => 'RateTooBig',
                message_params => ['1000000000.00'],
            },
            'Error when rate is too big'
        );
    };

    subtest 'floating rate' => sub {
        $params{rate_type} = 'float';

        cmp_deeply(
            exception {
                $advertiser->$method(%params, rate => 1.23);
            },
            {
                error_code => 'AdvertFloatRateNotAllowed',
            },
            'Error for new ad when floating ads disabled'
        );

        is(
            exception {
                $advertiser->$method(
                    %params,
                    rate      => 1.23,
                    is_active => 0,
                    old       => {rate_type => 'float'});
            },
            undef,
            'No error editing floating ad when floating ads disabled'
        );

        $config->country_advert_config(
            encode_json_utf8({
                    'id' => {
                        float_ads => 'enabled',
                        fixed_ads => 'disabled'
                    }}));

        is(
            exception {
                $advertiser->$method(%params, rate => 1.23);
            },
            undef,
            'No error creating floating ad when floating ads enabled in country'
        );

        for (1.231, -1.231, 1.661, 1.681, 0.001, -0.001, -0.9999999, -0.00009) {
            cmp_deeply(
                exception {
                    $advertiser->$method(%params, rate => $_);
                },
                {
                    error_code => 'FloatRatePrecision',
                },
                "Float rate of $_ too precise"
            );
        }

        for (1.230000, -1.230000, 1.66, 1.6600, 1.68, 1.6800, 0.000, 0, -0) {
            is(
                exception {
                    $advertiser->$method(%params, rate => $_);
                },
                undef,
                "Float rate of $_ is ok"
            );
        }

        $config->float_rate_global_max_range(10);

        cmp_deeply(
            exception {
                $advertiser->$method(%params, rate => 5.1);
            },
            {
                error_code     => 'FloatRateTooBig',
                message_params => ['5.00'],
            },
            'Eeror when rate above upper limit'
        );

        cmp_deeply(
            exception {
                $advertiser->$method(%params, rate => -5.1);
            },
            {
                error_code     => 'FloatRateTooBig',
                message_params => ['5.00'],
            },
            'Eeror when rate above lower limit'
        );

        $config->currency_config(encode_json_utf8({'IDR' => {max_rate_range => 2}}));

        cmp_deeply(
            exception {
                $advertiser->$method(%params, rate => 1.23);
            },
            {
                error_code     => 'FloatRateTooBig',
                message_params => ['1.00'],
            },
            'Eeror when rate outside currency specific limit'
        );

        $config->currency_config('{}');
        $config->country_advert_config('{}');
    };
};

$method = '_validate_advert_payment_contact_info';
subtest $method => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();

    is(
        exception {
            $advertiser->$method(%params, type => 'buy');
        },
        undef,
        'No error when buy ad has no contact info'
    );

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                contact_info => '',
                type         => 'sell'
            );
        },
        {error_code => 'AdvertContactInfoRequired'},
        'Error when sell ad has no contact info'
    );

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                contact_info => 'x',
                payment_info => ' ',
                type         => 'sell'
            );
        },
        {error_code => 'AdvertPaymentInfoRequired'},
        'Error when sell ad has no payment info'
    );

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                contact_info       => 'x',
                payment_info       => ' ',
                payment_method_ids => [],
                type               => 'sell'
            );
        },
        {error_code => 'AdvertPaymentInfoRequired'},
        'Error when sell ad has no payment in and empty payment_method_ids'
    );

    is(
        exception {
            $advertiser->$method(
                %params,
                contact_info => 'x',
                payment_info => 'y',
                type         => 'sell'
            );
        },
        undef,
        'No error when sell ad has contact info and payment info'
    );

    is(
        exception {
            $advertiser->$method(
                %params,
                contact_info       => 'x',
                payment_method_ids => [1, 2, 3],
                type               => 'sell'
            );
        },
        undef,
        'No error when sell ad has contact info and payment_method_ids'
    );

};

$method = '_validate_advert_duplicates';
subtest $method => sub {

    subtest 'duplicate rate' => sub {

        my $advertiser = BOM::Test::Helper::P2P::create_advertiser();
        $params{advertiser_id} = $advertiser->_p2p_advertiser_cached->{id};

        my $ad = $advertiser->p2p_advert_create(%params);

        cmp_deeply(
            exception {
                $advertiser->$method(%params)
            },
            {error_code => 'DuplicateAdvert'},
            'cannot create duplicate ad'
        );

        $advertiser->p2p_advert_update(
            id        => $ad->{id},
            is_active => 0
        );

        is(
            exception {
                $advertiser->$method(%params)
            },
            undef,
            'no error after disabling first ad'
        );

        $advertiser->p2p_advert_create(%params);

        cmp_deeply(
            exception {
                $advertiser->$method(%params)
            },
            {error_code => 'DuplicateAdvert'},
            'get error after creating a new ad'
        );

        is(
            exception {
                $advertiser->$method(%params, block_trade => 1)
            },
            undef,
            'no error for block trade'
        );
    };

    subtest 'overlapping range' => sub {

        my $advertiser = BOM::Test::Helper::P2P::create_advertiser();
        $params{advertiser_id} = $advertiser->_p2p_advertiser_cached->{id};

        my $ad = $advertiser->p2p_advert_create(
            %params,
            rate             => 1,
            min_order_amount => 1,
            max_order_amount => 10
        );

        cmp_deeply(
            exception {
                $advertiser->$method(
                    %params,
                    rate             => 1.1,
                    min_order_amount => 0.1,
                    max_order_amount => 9
                )
            },
            {error_code => 'AdvertSameLimits'},
            'error with overlapping max_order_amount'
        );

        cmp_deeply(
            exception {
                $advertiser->$method(
                    %params,
                    rate             => 1.1,
                    min_order_amount => 2,
                    max_order_amount => 9
                )
            },
            {error_code => 'AdvertSameLimits'},
            'error with inner range'
        );

        cmp_deeply(
            exception {
                $advertiser->$method(
                    %params,
                    rate             => 1.1,
                    min_order_amount => 0.1,
                    max_order_amount => 11
                )
            },
            {error_code => 'AdvertSameLimits'},
            'error with outer range'
        );

        is(
            exception {
                $advertiser->$method(
                    %params,
                    rate             => 1.1,
                    min_order_amount => 0.1,
                    max_order_amount => 11,
                    block_trade      => 1,
                )
            },
            undef,
            'no error for block trade with outer range'
        );

        $advertiser->p2p_advert_update(
            id        => $ad->{id},
            is_active => 0
        );

        is(
            exception {
                $advertiser->$method(
                    %params,
                    rate             => 1.1,
                    min_order_amount => 0.1,
                    max_order_amount => 11
                )
            },
            undef,
            'no error after ad disabled'
        );

        $advertiser->p2p_advert_create(
            %params,
            rate             => 1.1,
            min_order_amount => 1.1,
            max_order_amount => 11
        );

        is(
            exception {
                $advertiser->$method(
                    %params,
                    rate             => 1.2,
                    min_order_amount => 11.1,
                    max_order_amount => 11.2
                )
            },
            undef,
            'no error for new rate and non-overlapping range'
        );
    };

    subtest 'max ads of same type' => sub {

        my $advertiser = BOM::Test::Helper::P2P::create_advertiser();
        $params{advertiser_id} = $advertiser->_p2p_advertiser_cached->{id};

        $advertiser->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET trade_band = 'block_trade_medium' WHERE id = " . $params{advertiser_id});
        delete $advertiser->{_p2p_advertiser_cached};
        # limits are: normal = 5 - 500, block trade = 1000 to 10000

        $config->limits->maximum_ads_per_type(3);

        $advertiser->p2p_advert_create(
            %params,
            rate             => 1,
            min_order_amount => 5,
            max_order_amount => 6
        );
        $advertiser->p2p_advert_create(
            %params,
            rate             => 2,
            min_order_amount => 7,
            max_order_amount => 8
        );
        my $normal_ad = $advertiser->p2p_advert_create(
            %params,
            rate             => 3,
            min_order_amount => 9,
            max_order_amount => 10
        );

        $advertiser->p2p_advert_create(
            %params,
            block_trade      => 1,
            rate             => 1,
            amount           => 10000,
            min_order_amount => 1000,
            max_order_amount => 1001,

        );
        $advertiser->p2p_advert_create(
            %params,
            block_trade      => 1,
            rate             => 2,
            amount           => 10000,
            min_order_amount => 1002,
            max_order_amount => 1003
        );
        my $block_trade_ad = $advertiser->p2p_advert_create(
            %params,
            block_trade      => 1,
            rate             => 3,
            amount           => 10000,
            min_order_amount => 1004,
            max_order_amount => 1005
        );

        cmp_deeply(
            exception {
                $advertiser->$method(
                    %params,
                    rate             => 4,
                    min_order_amount => 11,
                    max_order_amount => 12
                )
            },
            {
                error_code     => 'AdvertMaxExceededSameType',
                message_params => [3],
            },
            'error for same ad type'
        );

        cmp_deeply(
            exception {
                $advertiser->$method(
                    %params,
                    block_trade      => 1,
                    rate             => 4,
                    amount           => 10000,
                    min_order_amount => 1006,
                    max_order_amount => 1007
                )
            },
            {
                error_code     => 'AdvertMaxExceededSameType',
                message_params => [3],
            },
            'error for same ad type for block trade ad'
        );

        is(exception { $advertiser->$method(%params, rate => 4, min_order_amount => 11, max_order_amount => 12, is_active => 0) },
            undef, 'no error for inactive ad');

        is(
            exception {
                $advertiser->$method(
                    %params,
                    rate             => 4,
                    amount           => 10000,
                    min_order_amount => 1006,
                    max_order_amount => 1007,
                    block_trade      => 1,
                    is_active        => 0
                )
            },
            undef,
            'no error for inactive block trade ad'
        );

        $advertiser->p2p_advert_update(
            id        => $normal_ad->{id},
            is_active => 0
        );

        is(exception { $advertiser->$method(%params, rate => 4, min_order_amount => 11, max_order_amount => 12) },
            undef, 'no error after disabling another ad');

        $advertiser->p2p_advert_update(
            id        => $block_trade_ad->{id},
            is_active => 0
        );

        is(
            exception {
                $advertiser->$method(
                    %params,
                    rate             => 4,
                    amount           => 10000,
                    min_order_amount => 1006,
                    max_order_amount => 1007,
                    block_trade      => 1
                )
            },
            undef,
            'no error after disabling block trade ad'
        );

    };

    subtest 'max active ads' => sub {

        my $advertiser = BOM::Test::Helper::P2P::create_advertiser(balance => 10);
        $params{advertiser_id} = $advertiser->_p2p_advertiser_cached->{id};

        my $ad;
        for my $num (1 .. 10) {
            is exception { $ad = $advertiser->p2p_advert_create(%params, local_currency => chr($num + 60) x 3) }, undef,
                "can create ${num}th ad with different currency";
        }

        cmp_deeply(
            exception {
                $advertiser->$method(%params)
            },
            {error_code => 'AdvertMaxExceeded'},
            'cannot have more than 10 active ads'
        );

        $advertiser->p2p_advert_update(
            id        => $ad->{id},
            is_active => 0
        );

        is(
            exception {
                $advertiser->$method(%params)
            },
            undef,
            'no error after one is deactivated'
        );

        my $ad2 = $advertiser->p2p_advert_create(%params, amount => 10);

        cmp_deeply(
            exception {
                $advertiser->$method(%params)
            },
            {error_code => 'AdvertMaxExceeded'},
            'error after an ad is created'
        );

        BOM::Test::Helper::P2P::create_order(
            advert_id => $ad2->{id},
            amount    => 10
        );

        is(exception { $advertiser->$method(%params) }, undef, 'no error if an ad is used up');
    };
};

$method = '_validate_advert_payment_method_type';
subtest $method => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                type                 => 'buy',
                payment_method       => '',
                payment_method_names => [],
                payment_method_ids   => []);
        },
        {error_code => 'AdvertPaymentMethodRequired'},
        'Error when no payment_methods for buy ad'
    );

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                type                 => 'sell',
                payment_method       => '',
                payment_method_names => [],
                payment_method_ids   => []);
        },
        {error_code => 'AdvertPaymentMethodRequired'},
        'Error when no payment_methods for buy ad'
    );

    is(
        exception {
            $advertiser->$method(
                %params,
                type           => 'buy',
                payment_method => 'x'
            );
        },
        undef,
        'Legacy buy ad, no error'
    );

    is(
        exception {
            $advertiser->$method(
                %params,
                type           => 'sell',
                payment_method => 'x'
            );
        },
        undef,
        'Legacy sell ad, no error'
    );

    my %params = %params;
    delete $params{payment_method};

    is(
        exception {
            $advertiser->$method(
                %params,
                type                 => 'buy',
                payment_method_names => ['x']);
        },
        undef,
        'New buy ad, no error'
    );

    is(
        exception {
            $advertiser->$method(
                %params,
                type               => 'sell',
                payment_method_ids => [1]);
        },
        undef,
        'New sell ad, no error'
    );

    is(
        exception {
            $advertiser->$method(%params, is_active => 0);
        },
        undef,
        'Inactive ad can have no payment methods'
    );

};

$method = '_validate_advert_payment_method_ids';
subtest $method => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(balance => 100);
    my %params     = (
        %params,
        type          => 'sell',
        advertiser_id => $advertiser->_p2p_advertiser_cached->{id});

    is(
        exception {
            $advertiser->$method(
                %params,
                type               => 'buy',
                payment_method_ids => []);
        },
        undef,
        'No error for buy ad and empty array'
    );

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                type               => 'buy',
                payment_method_ids => [1, 2]);
        },
        {error_code => 'AdvertPaymentMethodsNotAllowed'},
        'Error for buy ad with ids'
    );

    cmp_deeply(
        exception {
            $advertiser->$method(%params, payment_method_ids => [1, 2]);
        },
        {error_code => 'InvalidPaymentMethods'},
        'Invalid payment_method_ids'
    );

    my %pms = $advertiser->p2p_advertiser_payment_methods(
        create => [{
                method     => 'method1',
                is_enabled => 0,
            },
            {
                method     => 'method2',
                is_enabled => 0,
            }
        ],
    )->%*;
    %pms = map { $pms{$_}{method} => $_ } keys %pms;

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                is_active          => 1,
                payment_method     => '',
                payment_method_ids => [values %pms],
            );
        },
        {error_code => 'ActivePaymentMethodRequired'},
        'Inactive pms not ok for active ad'
    );

    is(
        exception {
            $advertiser->$method(
                %params,
                is_active          => 0,
                payment_method     => '',
                payment_method_ids => [values %pms],
            );
        },
        undef,
        'Inactive pms ok for inactive ad'
    );

    is(
        exception {
            $advertiser->$method(
                %params,
                is_active          => 1,
                payment_method     => 'x',
                payment_method_ids => [values %pms],
            );
        },
        undef,
        'Inactive pms ok if ad has payment_method'
    );

    $advertiser->p2p_advertiser_payment_methods(update => {$pms{method1} => {is_enabled => 1}});

    my $ad = $advertiser->p2p_advert_create(
        %params,
        payment_method     => '',
        payment_method_ids => [values %pms],
    );

    my $order1 = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad->{id},
        amount    => 10
    );

    $advertiser->p2p_advertiser_payment_methods(update => {$pms{method2} => {is_enabled => 1}});

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                id                 => $ad->{id},
                is_active          => 0,
                payment_method_ids => [$pms{method2}],
                active_orders      => 1
            );
        },
        {
            error_code     => 'PaymentMethodRemoveActiveOrders',
            message_params => ['Method 1']
        },
        'Cannot remove pm name from ad with active orders'
    );

    is(
        exception {
            $advertiser->$method(
                %params,
                id                 => $ad->{id},
                is_active          => 0,
                payment_method_ids => [$pms{method1}, $pms{method2}],
                active_orders      => 1
            );
        },
        undef,
        'PMs can be added when ad has active orders'
    );

    my $order2 = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad->{id},
        amount    => 10
    );

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                id                 => $ad->{id},
                is_active          => 0,
                payment_method_ids => [$pms{method2}],
                active_orders      => 1
            );
        },
        {
            error_code     => 'PaymentMethodRemoveActiveOrders',
            message_params => ['Method 1, Method 1, Method 2']
        },
        'Cannot remove pm name from ad with multiple active orders'
    );

    BOM::Test::Helper::P2P::set_order_status($advertiser, $order1->{id}, 'cancelled');
    BOM::Test::Helper::P2P::set_order_status($advertiser, $order2->{id}, 'cancelled');

    is(
        exception {
            $advertiser->$method(
                %params,
                id                 => $ad->{id},
                is_active          => 0,
                payment_method_ids => [$pms{method2}],
                active_orders      => 1
            );
        },
        undef,
        'Can remove pm name when no active orders'
    );
};

$method = '_validate_advert_payment_method_names';
subtest $method => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser;
    my %params     = (
        %params,
        type          => 'buy',
        advertiser_id => $advertiser->_p2p_advertiser_cached->{id});

    $config->payment_methods_enabled(0);

    is(
        exception {
            $advertiser->$method(%params, payment_method_names => []);
        },
        undef,
        'No error with empty array when pm feature is disabled'
    );

    cmp_deeply(
        exception {
            $advertiser->$method(%params, payment_method_names => ['method1']);
        },
        {error_code => 'PaymentMethodsDisabled'},
        'Error when pm feature is disabled'
    );

    $config->payment_methods_enabled(1);

    is(
        exception {
            $advertiser->$method(
                %params,
                type                 => 'sell',
                payment_method_names => []);
        },
        undef,
        'No error for sell ad with empty array'
    );

    cmp_deeply(
        exception {
            $advertiser->$method(
                %params,
                type                 => 'sell',
                payment_method_names => ['y', 'z']);
        },
        {error_code => 'AdvertPaymentMethodNamesNotAllowed'},
        'Error for sell ad'
    );

    cmp_deeply(
        exception {
            $advertiser->$method(%params, payment_method_names => ['x', 'method1']);
        },
        {
            error_code     => 'InvalidPaymentMethod',
            message_params => ['x']
        },
        'Invalid method name'
    );

    is(
        exception {
            $advertiser->$method(%params, payment_method_names => ['method1', 'method2']);
        },
        undef,
        'Valid names'
    );
};

$method = '_validate_advert_counterparty_terms';
subtest $method => sub {
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser;

    $config->restricted_countries(['id', 'ke']);

    cmp_deeply(
        exception {
            $advertiser->$method(%params, eligible_countries => ['za', 'ke', 'ng']);
        },
        {
            error_code     => 'InvalidCountry',
            message_params => ['ke']
        },
        'Restricted country'
    );

    is(
        exception {
            $advertiser->$method(%params, eligible_countries => ['ng', 'br']);
        },
        undef,
        'Unrestricted country'
    );

    $config->restricted_countries([]);

    cmp_deeply(
        exception {
            $advertiser->$method(%params, eligible_countries => ['ng', 'br', 'xx', 'ke']);
        },
        {
            error_code     => 'InvalidCountry',
            message_params => ['xx']
        },
        'Invalid country'
    );

    is(
        exception {
            $advertiser->$method(%params, eligible_countries => ['ng', 'br', 'za', 'ke']);
        },
        undef,
        'Valid countries'
    );
};

done_testing();
