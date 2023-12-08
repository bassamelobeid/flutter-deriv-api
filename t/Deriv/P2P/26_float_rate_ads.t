use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Exception;
use Test::Deep;
use Test::MockModule;
use List::Util      qw(pairs);
use JSON::MaybeUTF8 qw(:v1);

use BOM::User::Utility;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

my $rule_engine = BOM::Rules::Engine->new();

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_payment_methods();
BOM::Test::Helper::P2P::create_escrow();

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;

my $mock_client = Test::MockModule->new('Deriv::P2P');

my %params = (
    amount           => 100,
    min_order_amount => 1,
    max_order_amount => 10,
    payment_method   => 'bank_transfer',
    payment_info     => 'ad pay info',
    contact_info     => 'ad contact info',
    type             => 'sell',
);

subtest 'exchange rate' => sub {
    my $mock_converter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
    my $quote;
    $mock_converter->mock(usd_rate => sub { $quote });
    cmp_deeply BOM::User::Utility::p2p_exchange_rate('IDR'), {}, 'no feed';

    $quote = {
        quote => 0.5,
        epoch => 1000
    };
    cmp_ok BOM::User::Utility::p2p_exchange_rate('IDR')->{quote}, '==', 2, 'use feed';

    $config->currency_config(
        encode_json_utf8({
                IDR => {
                    manual_quote       => 2.1,
                    manual_quote_epoch => 1001
                }}));
    cmp_ok BOM::User::Utility::p2p_exchange_rate('IDR')->{quote}, '==', 2.1, 'use manual quote';

    $quote = {
        quote => 0.4,
        epoch => 1002
    };
    cmp_ok BOM::User::Utility::p2p_exchange_rate('IDR')->{quote}, '==', 2.5, 'recent feed replaces manual quote';

    $quote = {
        quote => 0.6,
        epoch => 1003
    };
    cmp_ok BOM::User::Utility::p2p_exchange_rate('IDR')->{quote}, '==', 1.666667, 'rate is rounded to 6 decimal places';

};

subtest 'float and fixed rates enabled/disabled scenarios' => sub {
    my $client = BOM::Test::Helper::P2P::create_advertiser;

    $mock_client->redefine(p2p_exchange_rate => {quote => 1});

    $config->country_advert_config(
        encode_json_utf8({
                $client->residence => {
                    float_ads => 'enabled',
                    fixed_ads => 'enabled'
                }}));

    is(
        exception {
            $client->p2p_advert_create(
                %params,
                rate             => 1,
                rate_type        => 'fixed',
                min_order_amount => 1,
                max_order_amount => 2,
            );
        },
        undef,
        'Create fixed ad ok'
    );
    my $ad;
    is(
        exception {
            $ad = $client->p2p_advert_create(
                %params,
                rate             => 1.23,
                rate_type        => 'float',
                min_order_amount => 3,
                max_order_amount => 4,
            );
        },
        undef,
        'Create float ad ok'
    );

    $config->country_advert_config(
        encode_json_utf8({
                $client->residence => {
                    float_ads => 'disabled',
                    fixed_ads => 'disabled'
                }}));

    cmp_deeply(
        exception {
            $client->p2p_advert_create(
                %params,
                rate             => 1,
                rate_type        => 'fixed',
                min_order_amount => 5,
                max_order_amount => 6,
            );
        },
        {
            error_code => 'AdvertFixedRateNotAllowed',
        },
        'Cannot create fixed ad when all disabled'
    );

    cmp_deeply(
        exception {
            $client->p2p_advert_create(
                %params,
                rate             => 1,
                rate_type        => 'float',
                min_order_amount => 5,
                max_order_amount => 6,
            );
        },
        {
            error_code => 'AdvertFloatRateNotAllowed',
        },
        'Cannot create float ad when all disabled'
    );

    $config->restricted_countries([$client->residence]);

    cmp_deeply(
        exception {
            $client->p2p_advert_create(
                %params,
                rate             => 1,
                rate_type        => 'float',
                min_order_amount => 5,
                max_order_amount => 6,
            );
        },
        {
            error_code => 'RestrictedCountry',
        },
        'Country disabled (advert_config does not contain country)'
    );

    $config->restricted_countries([]);

    $mock_client->redefine(p2p_exchange_rate => {});

    $config->country_advert_config(
        encode_json_utf8({
                $client->residence => {
                    float_ads => 'enabled',
                    fixed_ads => 'disabled'
                }}));

    cmp_deeply(
        exception {
            $client->p2p_advert_create(
                %params,
                rate             => 1,
                rate_type        => 'float',
                min_order_amount => 5,
                max_order_amount => 6,
            );
        },
        {
            error_code => 'AdvertFloatRateNotAllowed',
        },
        'Cannot create float ad when no exchange rate available'
    );

};

subtest 'converting ad rate types' => sub {

    my $client = BOM::Test::Helper::P2P::create_advertiser;
    $config->country_advert_config(
        encode_json_utf8({
                $client->residence => {
                    float_ads => 'disabled',
                    fixed_ads => 'enabled'
                }}));

    $mock_client->redefine(p2p_exchange_rate => {quote => 1});

    my $ad;
    is(
        exception {
            $ad = $client->p2p_advert_create(
                %params,
                rate      => 1,
                rate_type => 'fixed',
            );
        },
        undef,
        'No error creating fixed rate ad'
    );

    cmp_deeply(
        exception {
            $client->p2p_advert_update(
                id        => $ad->{id},
                rate_type => 'float',
            );
        },
        {
            error_code => 'AdvertFloatRateNotAllowed',
        },
        'Cannot convert ad to floating rate when floating ads disabled'
    );

    $config->country_advert_config(
        encode_json_utf8({
                $client->residence => {
                    float_ads => 'enabled',
                    fixed_ads => 'disabled'
                }}));

    is(
        exception {
            $ad = $client->p2p_advert_update(
                id   => $ad->{id},
                rate => 1.1,
            );
        },
        undef,
        'Can update rate of fixed ad when fixed ads are disabled'
    );
    is $ad->{rate}, 1.1, 'rate updated';

    # usually a cron will do this
    $client->p2p_advert_update(
        id        => $ad->{id},
        is_active => 0
    );

    cmp_deeply(
        exception {
            $client->p2p_advert_update(
                id        => $ad->{id},
                is_active => 1,
            );
        },
        {
            error_code => 'AdvertFixedRateNotAllowed',
        },
        'Cannot reactivate fixed ad when fixed ads disabled'
    );

    is(
        exception {
            $ad = $client->p2p_advert_update(
                id        => $ad->{id},
                rate      => -0.1,
                rate_type => 'float',
            );
        },
        undef,
        'Can convert fixed ad to floating rate when floating ads enabled'
    );

    is $ad->{rate}, -0.1, 'rate is set';

    cmp_deeply(
        exception {
            $client->p2p_advert_update(
                id        => $ad->{id},
                rate      => 1.1,
                rate_type => 'fixed',
            );
        },
        {
            error_code => 'AdvertFixedRateNotAllowed',
        },
        'Cannot convert floating to fixed rate when fixed ads disabled'
    );

    $config->country_advert_config(
        encode_json_utf8({
                $client->residence => {
                    float_ads => 'disabled',
                    fixed_ads => 'enabled'
                }}));

    is(
        exception {
            $ad = $client->p2p_advert_update(
                id   => $ad->{id},
                rate => -0.2,
            );
        },
        undef,
        'Can update rate of floating ad when floating ads are disabled'
    );
    is $ad->{rate}, -0.2, 'rate updated';

    # usually a cron will do this
    $client->p2p_advert_update(
        id        => $ad->{id},
        is_active => 0
    );

    cmp_deeply(
        exception {
            $client->p2p_advert_update(
                id        => $ad->{id},
                is_active => 1,
            );
        },
        {
            error_code => 'AdvertFloatRateNotAllowed',
        },
        'Cannot reactivate float ad when float ads disabled'
    );

    is(
        exception {
            $ad = $client->p2p_advert_update(
                id        => $ad->{id},
                rate      => 1.2,
                rate_type => 'fixed',
            );
        },
        undef,
        'Can convert floating to fixed when fixed is enabled'
    );
    is $ad->{rate}, 1.2, 'rate is set';

};

subtest 'rate fields' => sub {

    my $client = BOM::Test::Helper::P2P::create_advertiser(balance => 100);
    $config->country_advert_config(
        encode_json_utf8({
                $client->residence => {
                    float_ads => 'enabled',
                    fixed_ads => 'disabled'
                }}));

    $mock_client->redefine(p2p_exchange_rate => {quote => 100});

    my $ad;
    is(
        exception {
            $ad = $client->p2p_advert_create(
                %params,
                rate      => 0.1,
                rate_type => 'float',
            );
        },
        undef,
        'No error creating ad'
    );

    my %ads = (
        advert_create      => $ad,
        advert_info        => $client->p2p_advert_info(id => $ad->{id}),
        advertiser_adverts => $client->p2p_advertiser_adverts()->[0],
        advert_list        => $client->p2p_advert_list(advertiser_id => $client->_p2p_advertiser_cached->{id})->[0],
        advert_update      => $client->p2p_advert_update(
            id          => $ad->{id},
            description => 'x'
        ),

    );

    for my $k (keys %ads) {
        my $item = $ads{$k};
        cmp_ok $item->{rate}, '==', 0.10, "$k rate";
        is $item->{rate_display}, '+0.10', "$k rate_display";
        cmp_ok $item->{effective_rate}, '==', 100.1, "$k effective_rate";
        is $item->{effective_rate_display}, '100.10', "$k effective_rate_display";
        cmp_ok $item->{price}, '==', 100.1, "$k price";
        is $item->{price_display}, '100.10', "$k price_display";
    }

    my $buy_ad = $client->p2p_advert_create(
        %params,
        type      => 'buy',
        rate      => -1,
        rate_type => 'float',
    );

    is $buy_ad->{rate_display}, '-1.00', 'formatting of negative rate';
};

subtest 'orders' => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(balance => 100);
    $config->country_advert_config(
        encode_json_utf8({
                $advertiser->residence => {
                    float_ads => 'enabled',
                    fixed_ads => 'disabled'
                }}));

    $mock_client->redefine(p2p_exchange_rate => {quote => 100});

    my $ad = $advertiser->p2p_advert_create(
        %params,
        rate      => 0.1,
        rate_type => 'float',
    );

    my $client = BOM::Test::Helper::P2P::create_advertiser(client_details => {residence => $advertiser->residence});

    cmp_deeply(
        exception {
            $client->p2p_order_create(
                advert_id   => $ad->{id},
                amount      => 1,
                rule_engine => $rule_engine,
            );
        },
        {
            error_code => 'OrderCreateFailRateRequired',
        },
        'Must provide rate'
    );

    cmp_deeply(
        exception {
            $client->p2p_order_create(
                advert_id   => $ad->{id},
                amount      => 1,
                rate        => 100.11,
                rule_engine => $rule_engine,
            );
        },
        {
            error_code => 'OrderCreateFailRateChanged',
        },
        'Different rate not allowed'
    );

    my $order;
    is(
        exception {
            $order = $client->p2p_order_create(
                advert_id   => $ad->{id},
                amount      => 1,
                rate        => 100.1,
                rule_engine => $rule_engine,
            );
        },
        undef,
        'Order ok with matching rate'
    );

    cmp_ok $order->{rate}, '==', 100.1, 'order rate';
};

subtest 'ad list filtering' => sub {
    my $client = BOM::Test::Helper::P2P::create_advertiser(
        balance        => 100,
        client_details => {residence => 'ng'});
    $config->country_advert_config(
        encode_json_utf8({
                $client->residence => {
                    float_ads => 'enabled',
                    fixed_ads => 'enabled'
                }}));

    $mock_client->redefine(p2p_exchange_rate => {quote => 100});

    my $fixed_ad = $client->p2p_advert_create(
        %params,
        rate             => 1,
        rate_type        => 'fixed',
        min_order_amount => 1,
        max_order_amount => 2,
    );

    my $float_ad = $client->p2p_advert_create(
        %params,
        rate             => 1,
        rate_type        => 'float',
        min_order_amount => 3,
        max_order_amount => 4,
    );

    $mock_client->redefine(p2p_exchange_rate => {});
    cmp_bag([map { $_->{id} } $client->p2p_advert_list->@*], [$fixed_ad->{id}], 'fixed only when there is no rate');

    $mock_client->redefine(p2p_exchange_rate => {quote => 100});
    cmp_bag([map { $_->{id} } $client->p2p_advert_list->@*], [$fixed_ad->{id}, $float_ad->{id}], 'both shown when there is rate');
};

subtest 'advertiser active ads flags' => sub {
    my $client = BOM::Test::Helper::P2P::create_advertiser;

    $config->country_advert_config(
        encode_json_utf8({
                $client->residence => {
                    float_ads => 'enabled',
                    fixed_ads => 'enabled'
                }}));

    my (undef, $ad) = BOM::Test::Helper::P2P::create_advert(
        client           => $client,
        rate_type        => 'fixed',
        min_order_amount => 1,
        max_order_amount => 2
    );
    BOM::Test::Helper::P2P::create_advert(
        client           => $client,
        rate_type        => 'float',
        min_order_amount => 3,
        max_order_amount => 4,
        rate             => 1
    );
    BOM::Test::Helper::P2P::create_advert(
        client           => $client,
        rate_type        => 'float',
        min_order_amount => 5,
        max_order_amount => 6,
        rate             => 2
    );

    $config->country_advert_config(
        encode_json_utf8({
                $client->residence => {
                    float_ads => 'disabled',
                    fixed_ads => 'enabled'
                }}));

    ok !exists $client->p2p_advertiser_info->{active_float_ads}, 'active_float_ads not present';
    ok !exists $client->p2p_advertiser_info->{active_fixed_ads}, 'active_fixed_ads not present';

    $config->country_advert_config(
        encode_json_utf8({
                $client->residence => {
                    float_ads => 'disabled',
                    fixed_ads => 'list_only'
                }}));

    is $client->p2p_advertiser_info->{active_float_ads}, 2, 'active_float_ads exists and is correct';
    is $client->p2p_advertiser_info->{active_fixed_ads}, 1, 'active_fixed_ads exists and is correct';

    $client->p2p_advert_update(
        id        => $ad->{id},
        is_active => 0
    );
    ok !exists $client->p2p_advertiser_info->{active_fixed_ads}, 'active_fixed_ads not present when none';
};

done_testing();
