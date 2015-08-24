use Test::Most;
use Test::Mojo;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use JSON::Schema;
use File::Slurp;

use BOM::Platform::SessionCookie;

use Test::MockModule;
use Math::Util::CalculatedValue::Validatable;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange');

# We will 'cheat' our way through a contract-buy by stub-ing the probability calculations to .5..
# and we also avoid some real-time tick and volatility analysis, thus giving this a chance
# of working in static test environments such as Travis.
# We also mock is_expired so the portfolio call doesn't kick off sells.
my $value = Math::Util::CalculatedValue::Validatable->new({
    name        => 'x',
    description => 'x',
    set_by      => 'x',
    base_amount => .5
});
my $BPC = Test::MockModule->new('BOM::Product::Contract::Call');
$BPC->mock(_validate_underlying => undef);
$BPC->mock(_validate_volsurface => undef);
$BPC->mock(is_expired           => undef);
$BPC->mock(theo_probability     => $value);
$BPC->mock(ask_probability      => $value);
$BPC->mock(bid_probability      => $value);
my $BPT = Test::MockModule->new('BOM::Product::Transaction');
$BPT->mock(_build_pricing_comment => 'blah');

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(    # .. why isn't this in the testdb by default anyway?
    'exchange',
    {
        symbol                   => 'RANDOM',
        delay_amount             => 0,
        offered                  => 'yes',
        display_name             => 'Randoms',
        trading_timezone         => 'UTC',
        tenfore_trading_timezone => 'NA',
        open_on_weekends         => 1,
        currency                 => 'NA',
        bloomberg_calendar_code  => 'NA',
        holidays                 => {},
        market_times             => {
            early_closes => {},
            standard     => {
                daily_close      => '23h59m59s',
                daily_open       => '0s',
                daily_settlement => '23h59m59s',
            },
            partial_trading => {},
        },
        date => Date::Utility->new,
    });

my $config_dir = "$Bin/../../../config/v1";

my $t = Test::Mojo->new('BOM::WebSocketAPI');
$t->websocket_ok("/websockets/contracts");

my $token = BOM::Platform::SessionCookie->new(
    client_id       => 1,
    loginid         => "CR2002",
    email           => 'CR2002@binary.com',
    expiration_time => time() + 600,
    scopes          => ['price', 'trade'],
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'CR2002@binary.com';
is $authorize->{authorize}->{loginid}, 'CR2002';

$t = $t->send_ok({json => {ticks => 'R_50'}})->message_ok;
my $tick = decode_json($t->message->[1]);
ok $tick->{tick}->{id};
ok $tick->{tick}->{quote};
ok $tick->{tick}->{epoch};

my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$config_dir/tick/receive.json")));
my $result    = $validator->validate($tick);
ok $result, "tick response is valid";
# diag " - $_\n" foreach $result->errors;

# stop tick
$t = $t->send_ok({json => {forget => $tick->{tick}->{id}}})->message_ok;
my $forget = decode_json($t->message->[1]);
ok $forget->{forget};

$t = $t->send_ok({
        json => {
            "proposal"      => 1,
            "amount_val"    => "10",
            "basis"         => "payout",
            "contract_type" => "CALL",
            "currency"      => "USD",
            "symbol"        => "R_50",
            "duration"      => "15",
            "duration_unit" => "s"
        }})->message_ok;
my $proposal = decode_json($t->message->[1]);
ok $proposal->{proposal}->{id};
ok $proposal->{proposal}->{ask_price};

$validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$config_dir/get_price/receive.json")));
$result    = $validator->validate($proposal);
ok $result, "get_price response is valid";
# diag " - $_\n" foreach $result->errors;

sleep 1;
$t = $t->send_ok({
        json => {
            buy   => $proposal->{proposal}->{id},
            price => $proposal->{proposal}->{ask_price}}});

## skip proposal until we meet open_receipt
while (1) {
    $t = $t->message_ok;
    my $res = decode_json($t->message->[1]);
    next if $res->{msg_type} eq 'proposal';

    ok $res->{open_receipt};
    ok $res->{open_receipt}->{fmb_id};
    ok $res->{open_receipt}->{purchase_time};

    $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$config_dir/buy/receive.json")));
    $result    = $validator->validate($res);
    ok $result, "buy response is valid";
    # diag " - $_\n" foreach $result->errors;

    last;
}

$t->finish_ok;

done_testing();
