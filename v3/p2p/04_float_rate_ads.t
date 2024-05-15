use strict;
use warnings;

use Test::More;
use Test::Deep;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test test_schema/;
use await;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw(top_up);
use BOM::Test::Helper::P2P;
use BOM::User::Client;
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use JSON::MaybeUTF8 qw(:v1);

my $t = build_wsapi_test();

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

my $client_escrow = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'p2p_escrow@test.com'
});
$client_escrow->account('USD');

# Mocking all of the necessary exchange rates in redis.
my $redis_exchangerates = BOM::Config::Redis::redis_exchangerates_write();
my @all_currencies      = qw(EUR ETH AUD eUSDT tUSDT BTC LTC UST USDC USD GBP XRP);

for my $currency (@all_currencies) {
    $redis_exchangerates->hmset(
        'exchange_rates::' . $currency . '_USD',
        quote => 1,
        epoch => time
    );
}

$app_config->set({'payments.p2p.enabled'                  => 1});
$app_config->set({'system.suspend.p2p'                    => 0});
$app_config->set({'payments.p2p.available'                => 1});
$app_config->set({'payments.p2p.restricted_countries'     => []});
$app_config->set({'payments.p2p.available_for_currencies' => ['usd']});
$app_config->set({'payments.p2p.escrow'                   => [$client_escrow->loginid]});
$app_config->set({'payments.p2p.order_timeout'            => 3600});

$app_config->set({
        'payments.p2p.country_advert_config' => encode_json_utf8({
                'id' => {
                    float_ads => 'enabled',
                    fixed_ads => 'enabled',
                }})});

# if this test takes more than 10 minutues to run, it will fail if we get a quote for IDR. But then we have other problems :)
$app_config->set({
        'payments.p2p.currency_config' => encode_json_utf8({
                'IDR' => {
                    manual_quote       => 100,
                    manual_quote_epoch => time + 600,
                    max_rate_range     => 100
                }})});

BOM::Test::Helper::P2P::bypass_sendbird();
note explain(BOM::Config::Runtime->instance->app_config->payments->p2p->country_advert_config);

my $advertiser       = BOM::Test::Helper::P2P::create_advertiser(client_details => {residence => 'id'});
my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test', ['payments']);

my $client = BOM::Test::Helper::P2P::create_advertiser(
    balance        => 100,
    client_details => {residence => 'id'});
my $client_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test', ['payments']);

$app_config->check_for_update;

$t->await::authorize({authorize => $advertiser_token});

my $p2p_config = $t->await::website_status({website_status => 1})->{website_status}{p2p_config};
is($p2p_config->{float_rate_adverts}, 'enabled', 'float rate ads enabled in website_status') or note explain $p2p_config;
is($p2p_config->{fixed_rate_adverts}, 'enabled', 'fixed rate ads enabled in website_status') or note explain $p2p_config;

my $resp = $t->await::p2p_advert_create({
    p2p_advert_create => 1,
    amount            => 100,
    max_order_amount  => 10,
    min_order_amount  => 1,
    payment_method    => 'bank_transfer',
    type              => 'buy',
    rate_type         => 'float',
    rate              => -1.23,
});

ok(!$resp->{error}, 'no error for p2p_advert_create') or note explain $resp;
my $ad = $resp->{p2p_advert_create};

$resp = $t->await::p2p_advert_info({
    p2p_advert_info => 1,
    id              => $ad->{id},
});
ok(!$resp->{error}, 'no error for p2p_advert_info') or note explain $resp;

$resp = $t->await::p2p_advertiser_adverts({
    p2p_advertiser_adverts => 1,
});
ok(!$resp->{error}, 'no error for p2p_advertiser_adverts') or note explain $resp;

$resp = $t->await::p2p_advert_list({
    p2p_advert_list   => 1,
    counterparty_type => 'sell',
});
ok(!$resp->{error}, 'no error for p2p_advert_list') or note explain $resp;

$resp = $t->await::p2p_advert_update({
    p2p_advert_update => 1,
    id                => $ad->{id},
    rate              => -1.00,
});
ok(!$resp->{error}, 'no error for p2p_advert_update (update floating rate)') or note explain $resp;

$t->await::authorize({authorize => $client_token});

$resp = $t->await::p2p_order_create({
    p2p_order_create => 1,
    advert_id        => $ad->{id},
    rate             => 99.00,
    amount           => 10,
    contact_info     => 'xxx',
    payment_info     => 'xxx',
});
test_schema('p2p_order_create', $resp);
ok(!$resp->{error}, 'no error for p2p_order_create') or note explain $resp;

$t->await::authorize({authorize => $advertiser_token});

$resp = $t->await::p2p_advert_update({
    p2p_advert_update => 1,
    id                => $ad->{id},
    rate_type         => 'fixed',
    rate              => 99.99,
});
ok(!$resp->{error}, 'no error for p2p_advert_update (convert floating to fixed rate)') or note explain $resp;

$resp = $t->await::p2p_advert_create({
    p2p_advert_create => 1,
    amount            => 100,
    max_order_amount  => 10,
    min_order_amount  => 1,
    payment_method    => 'bank_transfer',
    contact_info      => 'x',
    payment_info      => 'x',
    type              => 'sell',
    rate_type         => 'fixed',
    rate              => 100.1,
});
ok(!$resp->{error}, 'no error to create a fixed ad') or note explain $resp;

$t->finish_ok;

done_testing();
