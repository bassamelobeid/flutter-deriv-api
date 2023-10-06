use strict;
use warnings;

use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::Config::CurrencyConfig;
use await;
use Test::More;
use Test::Deep;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test test_schema/;
use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use JSON::MaybeUTF8                            qw(:v1);

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

my $t             = build_wsapi_test();
my $client_escrow = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'p2p_escrow@test.com'
});
$client_escrow->account('USD');

my %vals = (
    adverts_active_limit        => 1,
    adverts_archive_period      => 2,
    cancellation_block_duration => 3,
    cancellation_count_period   => 4,
    cancellation_grace_period   => 5,
    cancellation_limit          => 6,
    maximum_advert_amount       => 7,
    maximum_order_amount        => 8,
    order_daily_limit           => 9,
    order_payment_period        => 10,
    supported_currencies        => ["usd"],
    disabled                    => bool(0),
    payment_methods_enabled     => bool(1),
    fixed_rate_adverts          => 'disabled',
    float_rate_adverts          => 'enabled',
    float_rate_offset_limit     => num(4.10),
    fixed_rate_adverts_end_date => '2012-02-03',
    review_period               => 13,
    feature_level               => 14,
    override_exchange_rate      => num(123.45),
    cross_border_ads_enabled    => bool(1),
    local_currencies            => ignore(),
    block_trade                 => {
        disabled              => 0,
        maximum_advert_amount => 15
    });

$app_config->set({'payments.p2p.available'                             => 1});
$app_config->set({'payments.p2p.enabled'                               => 1});
$app_config->set({'system.suspend.p2p'                                 => 0});
$app_config->set({'payments.p2p.payment_methods_enabled'               => 1});
$app_config->set({'payments.p2p.float_rate_global_max_range'           => 8.2});
$app_config->set({'payments.p2p.restricted_countries'                  => []});
$app_config->set({'payments.p2p.available_for_currencies'              => ['usd']});
$app_config->set({'payments.p2p.cross_border_ads_restricted_countries' => []});
$app_config->set({'payments.p2p.block_trade.enabled'                   => 1});
$app_config->set({'payments.p2p.escrow'                                => [$client_escrow->loginid]});
$app_config->set({'payments.p2p.archive_ads_days'                      => $vals{adverts_archive_period}});
$app_config->set({'payments.p2p.limits.maximum_ads_per_type'           => $vals{adverts_active_limit}});
$app_config->set({'payments.p2p.cancellation_barring.bar_time'         => $vals{cancellation_block_duration}});
$app_config->set({'payments.p2p.cancellation_barring.period'           => $vals{cancellation_count_period}});
$app_config->set({'payments.p2p.cancellation_grace_period'             => $vals{cancellation_grace_period}});
$app_config->set({'payments.p2p.cancellation_barring.count'            => $vals{cancellation_limit}});
$app_config->set({'payments.p2p.limits.maximum_advert'                 => $vals{maximum_advert_amount}});
$app_config->set({'payments.p2p.limits.maximum_order'                  => $vals{maximum_order_amount}});
$app_config->set({'payments.p2p.limits.count_per_day_per_client'       => $vals{order_daily_limit}});
$app_config->set({'payments.p2p.order_timeout'                         => $vals{order_payment_period} * 60});
$app_config->set({'payments.p2p.review_period'                         => $vals{review_period}});
$app_config->set({'payments.p2p.feature_level'                         => $vals{feature_level}});
$app_config->set({'payments.p2p.block_trade.maximum_advert'            => $vals{block_trade}->{maximum_advert_amount}});

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'client@test.com',
    residence   => 'id'
});

my $user = BOM::User->create(
    email    => 'client@test.com',
    password => 'test'
);
$user->add_client($client);
$client->account('USD');

my $currency              = BOM::Config::CurrencyConfig::local_currency_for_country(country => $client->residence);
my $country_advert_config = encode_json_utf8({
        'id' => {
            float_ads        => 'enabled',
            fixed_ads        => 'disabled',
            deactivate_fixed => '2012-02-03'
        }});

my $currency_config = encode_json_utf8({
        $currency => {
            manual_quote       => 123.45,
            manual_quote_epoch => time - 100,
            max_rate_range     => 8.2,
        }});

$app_config->set({'payments.p2p.currency_config'       => $currency_config});
$app_config->set({'payments.p2p.country_advert_config' => $country_advert_config});

my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test', ['payments']);
$t->await::authorize({authorize => $token});

my $resp = $t->await::p2p_settings({p2p_settings => 1});
cmp_deeply($resp->{p2p_settings}, \%vals, 'expected results');
test_schema('p2p_settings', $resp);

$t->finish_ok;

done_testing();
