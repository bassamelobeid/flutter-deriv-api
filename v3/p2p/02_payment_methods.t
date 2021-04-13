use strict;
use warnings;

use Test::More;
use Test::Deep;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test test_schema/;
use await;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use Guard;
use JSON::MaybeXS;

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
my $json = JSON::MaybeXS->new;

# We need to restore previous values when tests is done
my %init_config_values = (
    'payments.p2p.enabled'                  => $app_config->payments->p2p->enabled,
    'payments.p2p.available'                => $app_config->payments->p2p->available,
    'system.suspend.p2p'                    => $app_config->system->suspend->p2p,
    'payments.p2p.payment_method_countries' => $app_config->payments->p2p->payment_method_countries,
);

$app_config->set({'payments.p2p.enabled'   => 1});
$app_config->set({'payments.p2p.available' => 1});
$app_config->set({'system.suspend.p2p'     => 0});
$app_config->set({
        'payments.p2p.payment_method_countries' => $json->encode({
                bank_transfer => {mode => 'exclude'},
                other         => {mode => 'exclude'}})});

scope_guard {
    for my $key (keys %init_config_values) {
        $app_config->set({$key => $init_config_values{$key}});
    }
};

my $t = build_wsapi_test();

BOM::Test::Helper::P2P::bypass_sendbird();

my $client = BOM::Test::Helper::P2P::create_advertiser;
my $token  = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token', ['payments']);

$t->await::authorize({authorize => $token});

my $resp = $t->await::p2p_payment_methods({p2p_payment_methods => 1});
test_schema('p2p_payment_methods', $resp);

$resp = $t->await::p2p_advertiser_payment_methods({p2p_advertiser_payment_methods => 1});
test_schema('p2p_advertiser_payment_methods', $resp);

$t->finish_ok;

done_testing();
