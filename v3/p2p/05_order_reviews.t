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

$app_config->set({'payments.p2p.enabled'                                => 1});
$app_config->set({'system.suspend.p2p'                                  => 0});
$app_config->set({'payments.p2p.available'                              => 1});
$app_config->set({'payments.p2p.restricted_countries'                   => []});
$app_config->set({'payments.p2p.available_for_currencies'               => ['usd']});
$app_config->set({'payments.p2p.escrow'                                 => [$client_escrow->loginid]});
$app_config->set({'payments.p2p.review_period'                          => 2});
$app_config->set({'payments.p2p.transaction_verification_countries'     => []});
$app_config->set({'payments.p2p.transaction_verification_countries_all' => 0});
$app_config->set({'payments.p2p.order_timeout'                          => 3600});

BOM::Test::Helper::P2P::bypass_sendbird();

my ($advertiser, $ad)    = BOM::Test::Helper::P2P::create_advert();
my ($client,     $order) = BOM::Test::Helper::P2P::create_order(advert_id => $ad->{id});

my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test', ['payments']);
my $client_token     = BOM::Platform::Token::API->new->create_token($client->loginid,     'test', ['payments']);

$t->await::authorize({authorize => $client_token});
$t->await::p2p_order_confirm({
        p2p_order_confirm => 1,
        id                => $order->{id}});

$t->await::authorize({authorize => $advertiser_token});
$t->await::p2p_order_confirm({
        p2p_order_confirm => 1,
        id                => $order->{id}});

my $resp = $t->await::p2p_order_review({
    p2p_order_review => 1,
    order_id         => $order->{id},
    rating           => 4,
    recommended      => 1,
});

ok(!$resp->{error}, 'advertiser review ok') or note explain $resp;
test_schema('p2p_order_review', $resp);

$t->await::authorize({authorize => $client_token});

$resp = $t->await::p2p_order_review({
    p2p_order_review => 1,
    order_id         => $order->{id},
    rating           => 5,
    recommended      => undef,
});

ok(!$resp->{error}, 'client review ok') or note explain $resp;
test_schema('p2p_order_review', $resp);

$resp = $t->await::p2p_order_info({
    p2p_order_info => 1,
    order_id       => $order->{id},
});

test_schema('p2p_order_info', $resp);
$t->finish_ok;

done_testing();
