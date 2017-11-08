use strict;
use warnings;

use Test::Most;
use Date::Utility;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";

use BOM::Platform::RedisReplicated;
use Sereal::Encoder;
use BOM::Test::Helper qw/build_wsapi_test build_test_R_50_data/;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::MarketData qw(create_underlying);

use Quant::Framework;
use BOM::Platform::Chronicle;

use await;

use Test::MockModule;
use Mojo::Redis2;

my $redis2_module = Test::MockModule->new('Mojo::Redis2');
my $keys_hash     = {};
$redis2_module->mock(
    'subscribe',
    sub {
        my $redis = shift;
        my $keys  = shift;

        $keys_hash->{$_} = 1 for @$keys;
    });

$redis2_module->mock(
    'unsubscribe',
    sub {
        my $redis = shift;
        my $keys  = shift;

        delete($keys_hash->{$_}) for @$keys;
    });

my $sub_ids = {};
my @symbols = qw(frxUSDJPY frxAUDJPY frxAUDUSD);

my $encoder = Sereal::Encoder->new({
    canonical => 1,
});

my $time = time;
my @ticks;
for (my $i = $time - 1800; $i <= $time; $i += 15) {
    push @ticks,
        +{
        epoch          => $i,
        decimate_epoch => $i,
        quote          => 100 + rand(0.0001)};
}
my $redis = BOM::Platform::RedisReplicated::redis_write();

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
    $redis->zadd('DECIMATE_' . $s . '_15s_DEC', $_->{epoch}, $encoder->encode($_)) for @ticks;
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

my $authorize = $t->await::authorize({authorize => $token});

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

my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader());
my $underlying       = create_underlying('frxUSDJPY');

SKIP: {
    skip 'Forex test does not work on the weekends.', 1 if not $trading_calendar->is_open_at($underlying->exchange, Date::Utility->new);
    subtest 'forget' => sub {
        $t->await::forget_all({forget_all => 'proposal'});
        create_proposals();
        cmp_ok pricer_sub_count(), '==', 3, "3 pricer sub Ok";

        $res = $t->await::forget({forget => [values(%$sub_ids)]->[0]});
        cmp_ok $res->{forget}, '==', 1, 'Correct number of subscription forget';
        cmp_ok pricer_sub_count(), '==', 2, "price count checking";

        $res = $t->await::forget_all({forget_all => 'proposal'});
        is scalar @{$res->{forget_all}}, 2, 'Correct number of subscription forget';
        is pricer_sub_count(), 0, "price count checking";
    };
}

done_testing();

sub create_proposals {
    for my $s (@symbols) {
        $res = $t->await::proposal({%$req, symbol => $s});
        ok $res->{proposal}{id}, 'Should return id';
        $sub_ids->{$s} = $res->{proposal}->{id};
    }
}

sub pricer_sub_count {
    return scalar keys %$keys_hash;
}
