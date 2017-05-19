use strict;
use warnings;
use Test::More;
use Test::Deep;
use JSON;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data/;
use BOM::Database::Model::OAuth;
use BOM::Platform::RedisReplicated;
use BOM::Test::Data::Utility::FeedTestDatabase;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

initialize_realtime_ticks_db();
build_test_R_50_data();
my $now = Date::Utility->new;

my $t = build_wsapi_test();

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_50',
    epoch      => Date::Utility->new->epoch,
    quote      => 100
});

sub _create_tick {    #creates R_50 tick in redis channel FEED::R_50
    my ($i, $symbol) = @_;
    $i ||= 700;
    BOM::Platform::RedisReplicated::redis_write->publish("FEED::$symbol",
              "$symbol;"
            . Date::Utility->new->epoch . ';'
            . $i
            . ';60:7807.4957,7811.9598,7807.1055,7807.1055;120:7807.0929,7811.9598,7806.6856,7807.1055;180:7793.6775,7811.9598,7793.5814,7807.1055;300:7807.0929,7811.9598,7806.6856,7807.1055;600:7807.0929,7811.9598,7806.6856,7807.1055;900:7789.5519,7811.9598,7784.1465,7807.1055;1800:7789.5519,7811.9598,7784.1465,7807.1055;3600:7723.5128,7811.9598,7718.4277,7807.1055;7200:7723.5128,7811.9598,7718.4277,7807.1055;14400:7743.3676,7811.9598,7672.4463,7807.1055;28800:7743.3676,7811.9598,7672.4463,7807.1055;86400:7743.3676,7811.9598,7672.4463,7807.1055;'
    );
}

my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
});
$client->email($email);
$client->set_status('tnc_approval', 'system', BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version);
$client->save;

my @symbols = qw(frxUSDJPY frxAUDJPY frxAUDUSD);

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

subtest "new-tests" => sub {

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

my $res;

$t->send_ok({json => {forget_all => 'proposal'}})->message_ok;
my $prop_id = create_propsals($t, @symbols);
cmp_ok pricer_sub_count($t), '==', 3,"1 pricer sub Ok";

$t->send_ok({json => {forget => $prop_id}})->message_ok;
$res = decode_json($t->message->[1]);
cmp_ok $res->{forget}, '==', 1, 'Correct number of subscription forget';
cmp_ok pricer_sub_count($t), '==', 2, "2 pricer sub Ok";

$t->send_ok({json => {forget_all => 'proposal'}})->message_ok;
$res = decode_json($t->message->[1]);
is scalar @{$res->{forget_all}}, 2, 'Correct number of subscription forget';
cmp_ok pricer_sub_count($t), '==', 0, "1 pricer sub Ok";

};

subtest "old-tests" => sub {

local $SIG{__WARN__} = sub{};


# both these subscribtion should work as req_id is different
$t->send_ok({json => {ticks => 'R_50'}});
$t->send_ok({
        json => {
            ticks  => 'R_50',
            req_id => 1
        }});
my $pid = fork;
die "Failed fork for testing 'ticks' WS API call: $@" unless defined $pid;
unless ($pid) {
    sleep 1;
    _create_tick(700, 'R_50');
    sleep 1;
    exit;
}

my ($res, $ticks, @ids);
for (my $i = 0; $i < 2; $i++) {
    $t->message_ok;
    $res = decode_json($t->message->[1]);
    push @ids, $res->{tick}->{id};
    $ticks->{$res->{tick}->{symbol}}++;
}

$t->send_ok({json => {forget_all => 'ticks'}});
$t   = $t->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{forget_all}, "Manage to forget_all: ticks" or diag explain $res;
is scalar(@{$res->{forget_all}}), 2, "Forget the relevant tick channel";

@ids = sort @ids;
my @forget_ids = sort @{$res->{forget_all}};
cmp_bag(\@ids, \@forget_ids, 'correct forget ids for ticks');

$t->send_ok({
        json => {
            ticks_history => 'R_50',
            end           => "latest",
            count         => 10,
            style         => "candles",
            subscribe     => 1
        }});

$t->send_ok({
        json => {
            ticks_history => 'R_50',
            end           => "latest",
            count         => 10,
            style         => "candles",
            subscribe     => 1,
            req_id        => 1
        }});

$pid = fork;
die "Failed fork for testing 'ticks' WS API call: $@" unless defined $pid;
unless ($pid) {
    sleep 1;
    _create_tick(701, 'R_50');
    sleep 1;
    exit;
}

for (my $i = 0; $i < 2; $i++) {
    $t->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{msg_type}, "candles", 'correct message type';
}

@ids = ();
for (my $j = 0; $j < 2; $j++) {
    $t->message_ok;
    $res = decode_json($t->message->[1]);
    push @ids, $res->{ohlc}->{id};
    is $res->{msg_type}, "ohlc", 'correct message type';
}

$t->send_ok({json => {forget_all => 'candles'}});
$t   = $t->message_ok;
$res = JSON::from_json($t->message->[1]);
ok $res->{forget_all}, "Manage to forget_all: candles" or diag explain $res;
is scalar(@{$res->{forget_all}}), 2, "Forget the relevant candle feed channel";
test_schema('forget_all', $res);

@forget_ids = sort @{$res->{forget_all}};
cmp_bag(\@ids, \@forget_ids, 'correct forget ids for ticks history');

};

$t->finish_ok;
done_testing();

sub create_propsals {
    my $t = shift;
    my $req = {
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
    my $first_prop_id;
    for my $s (@_) {
        $req->{symbol} = $s;
        $t->send_ok({json => $req})->message_ok;
        my $res = decode_json($t->message->[1]);
        ok $res->{proposal}->{id}, 'Should return id';
        $first_prop_id = $res->{proposal}->{id} unless $first_prop_id;
    }
    return $first_prop_id;
}

sub pricer_sub_count {
    my $t = shift;
    return scalar @{ $t->app->redis_pricer->keys( 'PRICER_KEYS::*') };
}

