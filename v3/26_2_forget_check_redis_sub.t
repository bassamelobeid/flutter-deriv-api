use strict;
use warnings;

use Test::Most;
use JSON;
use Date::Utility;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";

use BOM::Test::Helper qw/build_wsapi_test build_test_R_50_data/;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Test::RPC::BomRpc;
use BOM::Test::RPC::PricingRpc;

my $sub_ids = {};
my @symbols = qw(frxUSDJPY frxAUDJPY frxAUDUSD);

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for qw(USD JPY AUD JPY-USD AUD-USD AUD-JPY);

for my $s (@symbols) {
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $s,
            recorded_date => $now,
        });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        quote      => 98,
        epoch      => $now->epoch - 2,
        underlying => $s,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        quote      => 99,
        epoch      => $now->epoch - 1,
        underlying => $s,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        quote      => 100,
        epoch      => $now->epoch,
        underlying => $s,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        quote      => 101,
        epoch      => $now->epoch + 1,
        underlying => $s,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        quote      => 102,
        epoch      => $now->epoch + 2,
        underlying => $s,
    });
}

build_test_R_50_data();

my $t = build_wsapi_test();

# prepare client
my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->set_status('tnc_approval', 'system', BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version);
$client->save;
my $loginid = $client->loginid;
my $user    = BOM::Platform::User->create(
    email    => $email,
    password => '1234',
);
$user->add_loginid({loginid => $loginid});
$user->save;

$client->set_default_account('USD');
$client->smart_payment(
    currency     => 'USD',
    amount       => +300000,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);

my ($req, $res, $start, $end);
$req = {
    "proposal"      => 1,
    "subscribe"     => 1,
    "amount"        => 10,
    "basis"         => "payout",
    "contract_type" => "CALL",
    "currency"      => "USD",
    "symbol"        => "frxUSDJPY",
    "duration"      => 5,
    "duration_unit" => "m",
};

$t->send_ok({json => {forget_all => 'proposal'}})->message_ok;
create_propsals();
cmp_ok pricer_sub_count(), '==', 3, "3 pricer sub Ok";

$t->send_ok({json => {forget => [values(%$sub_ids)]->[0]}})->message_ok;
$res = decode_json($t->message->[1]);
cmp_ok $res->{forget}, '==', 1, 'Correct number of subscription forget';
cmp_ok pricer_sub_count(), '==', 3, "3 pricer sub Ok";

$t->send_ok({json => {forget_all => 'proposal'}})->message_ok;
$res = decode_json($t->message->[1]);
is scalar @{$res->{forget_all}}, 2, 'Correct number of subscription forget';
cmp_ok pricer_sub_count(), '==', 3, "3 pricer sub Ok";

done_testing();

sub create_propsals {
    for my $s (@symbols) {
        $req->{symbol} = $s;
        $t->send_ok({json => $req})->message_ok;
        $res = decode_json($t->message->[1]);
        ok $res->{proposal}->{id}, 'Should return id';
        $sub_ids->{$s} = $res->{proposal}->{id};
    }
}

sub pricer_sub_count {
    return scalar @{$t->app->redis_pricer->keys('PRICER_KEYS::*')};
}

