use Test::Most;
use Test::Mojo;
use JSON;
use Data::Dumper;
use Test::MockModule;

use BOM::Platform::SessionCookie;
use BOM::Market::Underlying;
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

my $svr = $ENV{BOM_WEBSOCKETS_SVR} || '';
my $t = $svr ? Test::Mojo->new : Test::Mojo->new('BOM::WebSocketAPI');

$t->websocket_ok("$svr/websockets/contracts");

my $CR0005_token = BOM::Platform::SessionCookie->new(
    client_id       => 1,
    loginid         => "CR2002",
    email           => 'CR2002@binary.com',
    expiration_time => time() + 600,
    scopes          => ['price', 'trade'],
)->token;

$t = $t->send_ok({json => {authorize => $CR0005_token}})->message_ok;
diag Dumper(\$t->message);
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'CR2002@binary.com';
is $authorize->{authorize}->{loginid}, 'CR2002';

$t = $t->send_ok({json => {ticks => 'R_50'}})->message_ok;
diag Dumper(\$t->message);
my $tick = decode_json($t->message->[1]);
ok $tick->{tick}->{id};
ok $tick->{tick}->{quote};
ok $tick->{tick}->{epoch};

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
diag Dumper($proposal);
ok $proposal->{proposal}->{id};
ok $proposal->{proposal}->{ask_price};

$t = $t->send_ok({
        json => {
            buy   => $proposal->{proposal}->{id},
            price => $proposal->{proposal}->{ask_price}}})->message_ok;
my $res = decode_json($t->message->[1]);
diag Dumper(\$res);
ok $res->{open_receipt};
ok $res->{open_receipt}->{fmb_id};
ok $res->{open_receipt}->{purchase_time};

# $t = $t->send_ok({json => {portfolio => 1}})->message_ok;
# diag Dumper(decode_json($t->message->[1]));

# $t = $t->send_ok({
#     json => {
#         sell => $res->{open_receipt}->{fmb_id},
#         price => $proposal->{proposal}->{ask_price}
#     }
# })->message_ok;
# $res = decode_json($t->message->[1]);
# diag Dumper(\$res);
# ok $res->{close_receipt};
# ok $res->{close_receipt}->{fmb_id};
# ok $res->{close_receipt}->{purchase_time};

$t->finish_ok;

done_testing();
