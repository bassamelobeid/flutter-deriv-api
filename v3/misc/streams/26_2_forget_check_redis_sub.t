use strict;
use warnings;

use Test::Most;
use Date::Utility;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";

my (%stats, %tags);

BEGIN {
    require DataDog::DogStatsd::Helper;
    no warnings 'redefine';
    *DataDog::DogStatsd::Helper::stats_timing = sub {
        my ($key, $val, $tag) = @_;
        $stats{$key} = $val;
        ++$tags{$tag->{tags}[0]};
    };
}

is_deeply(\%stats, {}, 'start with no metrics');
is_deeply(\%tags,  {}, 'start with no tags');

use BOM::Config::RedisReplicated;
use Sereal::Encoder;
use BOM::Test::Helper qw/build_wsapi_test build_test_R_50_data/;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::MarketData qw(create_underlying);
use BOM::Product::ContractFactory qw(produce_contract);

use Quant::Framework;
use BOM::Config::Chronicle;

use await;

use Test::MockObject::Extends;
use Mojo::Redis2;
use Binary::WebSocketAPI::v3::Instance::Redis qw| redis_pricer |;

my $t            = build_wsapi_test();
my $redis_pricer = Test::MockObject::Extends->new(redis_pricer);

my $keys_hash = {};
$redis_pricer->mock(
    'subscribe',
    sub {
        my $redis = shift;
        my $keys  = shift;
        $keys_hash->{$_} = 1 for @$keys;
    });

$redis_pricer->mock(
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
my $redis = BOM::Config::RedisReplicated::redis_write();

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

# prepare client
my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->status->set('tnc_approval', 'system', BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_version);
$client->save;
my $loginid = $client->loginid;
my $user    = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($client);

$client->set_default_account('USD');
$client->smart_payment(
    currency     => 'USD',
    amount       => +300000,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

my $authorize = $t->await::authorize({authorize => $token});
ok !$authorize->{error}, 'Authorized successfully';

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

my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader());
my $underlying       = create_underlying('frxUSDJPY');
$res = $t->await::proposal($req);
my $quite_hour_error = ($res->{error}->{code} // '' eq 'ContractBuyValidationError') && ($res->{error}->{details}->{field} // '' eq 'duration');
my $skip = !$trading_calendar->is_open_at($underlying->exchange, Date::Utility->new) || $quite_hour_error;

SKIP: {
    skip 'Forex test does not work on the weekends and quite hours.', 1 if $skip;
    subtest 'forget' => sub {
        $t->await::forget_all({forget_all => 'proposal'});
        create_proposals();
        cmp_ok pricer_sub_count(), '==', 6, "6 pricer sub Ok";

        $res = $t->await::forget({forget => [values(%$sub_ids)]->[0]});
        cmp_ok $res->{forget}, '==', 1, 'Correct number of subscription forget';
        cmp_ok pricer_sub_count(), '==', 5, "price count checking";

        $res = $t->await::forget_all({forget_all => 'proposal'});
        is scalar @{$res->{forget_all}}, 5, 'Correct number of subscription forget';
        is pricer_sub_count(), 0, "price count checking";
    };
}

done_testing();

sub create_proposals {
    for my $s (@symbols) {
        for my $ct (qw(CALL PUT)) {
            $res = $t->await::proposal({
                    %$req,
                    symbol        => $s,
                    contract_type => $ct
                },
                {timeout => 5});
            note explain \%stats, \%tags;
            ok $res->{proposal}{id}, 'Should return id';
            $sub_ids->{$s} = $res->{proposal}->{id};
        }
    }
}

sub pricer_sub_count {
    return scalar keys %$keys_hash;
}
