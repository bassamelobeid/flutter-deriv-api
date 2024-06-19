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

my $advertiser = BOM::Test::Helper::P2P::create_advertiser(
    balance        => 100,
    client_details => {residence => 'id'});
my $client = BOM::Test::Helper::P2P::create_advertiser(client_details => {residence => 'id'});

my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test', ['payments']);
my $client_token     = BOM::Platform::Token::API->new->create_token($client->loginid,     'test', ['payments']);

$t->await::authorize({authorize => $advertiser_token});
my $resp = $t->await::p2p_advert_create({
        p2p_advert_create   => 1,
        type                => 'sell',
        min_order_amount    => 1,
        max_order_amount    => 100,
        amount              => 100,
        payment_method      => 'bank_transfer',
        contact_info        => 'x',
        payment_info        => 'x',
        rate                => 1,
        min_completion_rate => 55.555555,
        min_rating          => 4.5555555,
        min_join_days       => 88,
        eligible_countries  => ['za', 'id']});

ok(!$resp->{error}, 'no error for p2p_advert_create') or note explain $resp;
my $id = $resp->{p2p_advert_create}{id};

$resp = $t->await::p2p_advert_info({
    p2p_advert_info => 1,
    id              => $id
});

ok(!$resp->{error}, 'no error for advertiser p2p_advert_info') or note explain $resp;

$resp = $t->await::p2p_advertiser_adverts({p2p_advertiser_adverts => 1});

ok(!$resp->{error}, 'no error for p2p_advertiser_adverts') or note explain $resp;

$resp = $t->await::p2p_advert_list({
    p2p_advert_list   => 1,
    counterparty_type => 'buy'
});

ok(!$resp->{error}, 'no error for adveritiser p2p_advert_list') or note explain $resp;

$resp = $t->await::p2p_advert_update({
        p2p_advert_update   => 1,
        id                  => $id,
        min_completion_rate => 88.888,
        min_rating          => 3.3333,
        min_join_days       => 24,
        eligible_countries  => ['za', 'ke']});

ok(!$resp->{error}, 'no error for p2p_advert_update') or note explain $resp;

$resp = $t->await::p2p_advert_update({
    p2p_advert_update   => 1,
    id                  => $id,
    min_completion_rate => undef,
    min_rating          => undef,
    min_join_days       => undef,
    eligible_countries  => undef
});

ok(!$resp->{error}, 'no error for p2p_advert_update with null values') or note explain $resp;

$t->await::authorize({authorize => $client_token});
$resp = $t->await::p2p_advert_info({
    p2p_advert_info => 1,
    id              => $id
});

ok(!$resp->{error}, 'no error for client p2p_advert_info') or note explain $resp;

$resp = $t->await::p2p_advert_list({
    p2p_advert_list   => 1,
    counterparty_type => 'buy',
});

ok(!$resp->{error}, 'no error for client p2p_advert_list') or note explain $resp;

$resp = $t->await::p2p_advert_list({
    p2p_advert_list   => 1,
    counterparty_type => 'buy',
    hide_ineligible   => 1,
});

ok(!$resp->{error}, 'no error for client p2p_advert_list with hide_ineligible') or note explain $resp;

done_testing();
