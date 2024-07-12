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
use BOM::Test::Customer;
use BOM::Test::Helper::P2P;
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use JSON::MaybeXS;
use List::Util qw(first);

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
my $json = JSON::MaybeXS->new;

my $customer = BOM::Test::Customer->create(
    email_verified => 1,
    residence      => 'id',
    clients        => [{
            name            => 'CR',
            broker_code     => 'CR',
            default_account => 'USD'
        },
    ]);

$app_config->set({'system.suspend.p2p'     => 0});
$app_config->set({'payments.p2p.enabled'   => 1});
$app_config->set({'payments.p2p.available' => 1});
$app_config->set({'payments.p2p.escrow'    => [$customer->get_client_loginid('CR')]});
$app_config->set({
        'payments.p2p.payment_method_countries' => $json->encode({
                bank_transfer => {mode => 'exclude'},
                other         => {mode => 'exclude'}})});
$app_config->set({'payments.p2p.payment_methods_enabled'                => 1});
$app_config->set({'payments.p2p.transaction_verification_countries'     => []});
$app_config->set({'payments.p2p.transaction_verification_countries_all' => 0});

my $t = build_wsapi_test();

BOM::Test::Helper::P2P::bypass_sendbird();

subtest 'p2p country list' => sub {

    my $advertiser       = BOM::Test::Helper::P2P::create_advertiser(balance => 1000);
    my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test', ['payments']);
    $t->await::authorize({authorize => $advertiser_token});

    my $resp = $t->await::p2p_country_list({p2p_country_list => 1});
    test_schema('p2p_country_list', $resp);

    $resp = $t->await::p2p_country_list({p2p_country_list => 1, country => 'id'});
    test_schema('p2p_country_list', $resp);

    is $resp->{p2p_country_list}->{id}->{country_name},             'Indonesia', 'country name is correct';
    is $resp->{p2p_country_list}->{id}->{local_currency},           'IDR',       'currency name is correct';
    is $resp->{p2p_country_list}->{id}->{cross_border_ads_enabled}, 1,           'currency name is correct';

};

$t->finish_ok;

done_testing();
