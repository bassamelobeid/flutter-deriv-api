use strict;
use warnings;

use Test::More;
use Test::Fatal qw(exception lives_ok);
use Test::Deep;
use JSON::MaybeUTF8 qw(:v1);

use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();
BOM::Test::Helper::P2P::create_payment_methods();

my $p2p_config  = BOM::Config::Runtime->instance->app_config->payments->p2p;
my $rule_engine = BOM::Rules::Engine->new();

$p2p_config->payment_methods_enabled(1);
$p2p_config->transaction_verification_countries([]);
$p2p_config->transaction_verification_countries_all(0);
$p2p_config->payment_method_countries(
    encode_json_utf8({
            method1 => {
                mode      => 'include',
                countries => ['id']
            },
            method2 => {mode => 'exclude'},
            method3 => {
                mode      => 'include',
                countries => ['ng']}}));

my $advertiser_id = BOM::Test::Helper::P2P::create_advertiser(
    balance        => 1000,
    client_details => {residence => 'id'});
my $advertiser_ng = BOM::Test::Helper::P2P::create_advertiser(
    balance        => 1000,
    client_details => {residence => 'ng'});

my $methods_id = $advertiser_id->p2p_advertiser_payment_methods(create => [{method => 'method1'}, {method => 'method2'}]);
my $methods_ng = $advertiser_ng->p2p_advertiser_payment_methods(create => [{method => 'method2'}, {method => 'method3'}]);

# sell ad with common pm
my (undef, $ad_sell_id_1) = BOM::Test::Helper::P2P::create_advert(
    client             => $advertiser_id,
    type               => 'sell',
    rate               => 1,
    min_order_amount   => 1,
    max_order_amount   => 2,
    payment_method_ids => [keys %$methods_id]);
my (undef, $ad_sell_ng_1) = BOM::Test::Helper::P2P::create_advert(
    client             => $advertiser_ng,
    type               => 'sell',
    rate               => 1,
    min_order_amount   => 1,
    max_order_amount   => 2,
    payment_method_ids => [keys %$methods_ng]);
# sell ad with country specific pm
my (undef, $ad_sell_id_2) = BOM::Test::Helper::P2P::create_advert(
    client             => $advertiser_id,
    type               => 'sell',
    rate               => 2,
    min_order_amount   => 3,
    max_order_amount   => 4,
    payment_method_ids => [grep { $methods_id->{$_}{method} eq 'method1' } keys %$methods_id]);
my (undef, $ad_sell_ng_2) = BOM::Test::Helper::P2P::create_advert(
    client             => $advertiser_ng,
    type               => 'sell',
    rate               => 2,
    min_order_amount   => 3,
    max_order_amount   => 4,
    payment_method_ids => [grep { $methods_ng->{$_}{method} eq 'method3' } keys %$methods_ng]);
# buy ad with common pm
my (undef, $ad_buy_id_1) = BOM::Test::Helper::P2P::create_advert(
    client               => $advertiser_id,
    type                 => 'buy',
    rate                 => 1,
    min_order_amount     => 1,
    max_order_amount     => 2,
    payment_method_names => ['method1', 'method2'],
);
my (undef, $ad_buy_ng_1) = BOM::Test::Helper::P2P::create_advert(
    client               => $advertiser_ng,
    type                 => 'buy',
    rate                 => 1,
    min_order_amount     => 1,
    max_order_amount     => 2,
    payment_method_names => ['method2', 'method3'],
);
# buy ad with country specific pm
my (undef, $ad_buy_id_2) = BOM::Test::Helper::P2P::create_advert(
    client               => $advertiser_id,
    type                 => 'buy',
    rate                 => 2,
    min_order_amount     => 3,
    max_order_amount     => 4,
    payment_method_names => ['method1'],
);
my (undef, $ad_buy_ng_2) = BOM::Test::Helper::P2P::create_advert(
    client               => $advertiser_ng,
    type                 => 'buy',
    rate                 => 2,
    min_order_amount     => 3,
    max_order_amount     => 4,
    payment_method_names => ['method3'],
);

subtest 'advert list' => sub {

    cmp_deeply([
            map { $_->{id} } $advertiser_id->p2p_advert_list(
                local_currency    => $advertiser_ng->local_currency,
                counterparty_type => 'buy'
            )->@*
        ],
        [$ad_sell_ng_1->{id}],
        'expected ng sell ads seen by id user'
    );

    cmp_deeply([
            map { $_->{id} } $advertiser_ng->p2p_advert_list(
                local_currency    => $advertiser_id->local_currency,
                counterparty_type => 'buy'
            )->@*
        ],
        [$ad_sell_id_1->{id}],
        'expected id sell ads seen by ng user'
    );

    cmp_deeply([
            map { $_->{id} } $advertiser_id->p2p_advert_list(
                local_currency    => $advertiser_ng->local_currency,
                counterparty_type => 'sell'
            )->@*
        ],
        [$ad_buy_ng_1->{id}],
        'expected ng buy ads seen by id user'
    );

    cmp_deeply([
            map { $_->{id} } $advertiser_ng->p2p_advert_list(
                local_currency    => $advertiser_id->local_currency,
                counterparty_type => 'sell'
            )->@*
        ],
        [$ad_buy_id_1->{id}],
        'expected id buy ads seen by ng user'
    );

    cmp_deeply([
            map { $_->{id} } $advertiser_id->p2p_advert_list(
                local_currency    => $advertiser_id->local_currency,
                counterparty_type => 'buy'
            )->@*
        ],
        bag($ad_sell_id_1->{id}, $ad_sell_id_2->{id}),
        'expected id sell ads seen by id user'
    );

    cmp_deeply([
            map { $_->{id} } $advertiser_id->p2p_advert_list(
                local_currency    => $advertiser_id->local_currency,
                counterparty_type => 'sell'
            )->@*
        ],
        bag($ad_buy_id_1->{id}, $ad_buy_id_2->{id}),
        'expected id buy ads seen by id user'
    );

    cmp_deeply($advertiser_ng->p2p_advert_info(id => $ad_sell_id_1->{id})->{payment_method_names},
        ['Method 2'], 'user in other contry does not see incompatible payment methods');

    cmp_deeply(
        $advertiser_id->p2p_advert_info(id => $ad_sell_id_1->{id})->{payment_method_names},
        ['Method 1', 'Method 2'],
        'ad owner sees all payment methods in p2p_advert_info'
    );
};

subtest 'orders' => sub {

    cmp_deeply(
        exception { $advertiser_id->p2p_order_create(advert_id => $ad_sell_ng_2->{id}, amount => 3, rule_engine => $rule_engine) },
        {error_code => 'AdvertNotFound'},
        'cannot order ad with invalid pms'
    );

    lives_ok {
        my $order = $advertiser_id->p2p_order_create(
            advert_id   => $ad_sell_ng_1->{id},
            amount      => 1,
            rule_engine => $rule_engine
        );
        $advertiser_id->p2p_order_confirm(id => $order->{id});
        $advertiser_ng->p2p_order_confirm(id => $order->{id});
    }
    'can complete buy order of other currency';

    lives_ok {
        my $order = $advertiser_id->p2p_order_create(
            advert_id          => $ad_buy_ng_1->{id},
            amount             => 1,
            payment_method_ids => [grep { $methods_id->{$_}{method} eq 'method2' } keys %$methods_id],
            contact_info       => 'x',
            rule_engine        => $rule_engine
        );
        $advertiser_ng->p2p_order_confirm(id => $order->{id});
        $advertiser_id->p2p_order_confirm(id => $order->{id});
    }
    'can complete sell order of other currency';
};

subtest 'floating rate ads' => sub {

    $p2p_config->country_advert_config(
        encode_json_utf8({
                'lk' => {
                    float_ads => 'enabled',
                    fixed_ads => 'disabled'
                },
                'za' => {
                    float_ads => 'enabled',
                    fixed_ads => 'disabled'
                }}));

    $p2p_config->currency_config(
        encode_json_utf8({
                'LKR' => {
                    manual_quote       => 100,
                    manual_quote_epoch => time(),
                }}));

    my (undef, $ad) = BOM::Test::Helper::P2P::create_advert(
        rate_type  => 'float',
        rate       => 0.1,
        advertiser => {residence => 'lk'});
    cmp_ok $ad->{effective_rate}, '==', 100.1, 'rate returned from ad create';

    my $za_advertiser = BOM::Test::Helper::P2P::create_advertiser(client_details => {residence => 'za'});

    cmp_ok $za_advertiser->p2p_advert_info(id => $ad->{id})->{effective_rate}, '==', 100.1,
        'advertiser in other country gets correct ad rate from p2p_advert_info';
    cmp_ok $za_advertiser->p2p_advert_list(local_currency => 'LKR')->[0]->{effective_rate}, '==', 100.1,
        'advertiser in other country gets correct ad rate from p2p_advert_list';

    my $order = $za_advertiser->p2p_order_create(
        advert_id   => $ad->{id},
        amount      => 10,
        rate        => 100.1,
        rule_engine => $rule_engine
    );
    cmp_ok $order->{rate},                                             '==', 100.1, 'created order has correct rate';
    cmp_ok $za_advertiser->p2p_order_info(id => $order->{id})->{rate}, '==', 100.1, 'p2p_order_info has correct rate';
};

done_testing();
