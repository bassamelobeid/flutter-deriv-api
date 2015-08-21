use strict;
use warnings;
use Test::More;
use Test::Mojo;
use JSON;
use Data::Dumper;
use Date::Utility;

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

my $t = Test::Mojo->new('BOM::WebSocketAPI');
$t->websocket_ok("/websockets/contracts");

# test payout_currencies
$t = $t->send_ok({json => {payout_currencies => 1}})->message_ok;
my $payout_currencies = decode_json($t->message->[1]);
ok($payout_currencies->{payout_currencies});
ok(grep { $_ eq 'USD' } @{$payout_currencies->{payout_currencies}});

# test active_symbols
$t = $t->send_ok({json => {active_symbols => 'symbol'}})->message_ok;
my $active_symbols = decode_json($t->message->[1]);
ok($active_symbols->{active_symbols});
ok($active_symbols->{active_symbols}->{R_50});

$t = $t->send_ok({json => {active_symbols => 'display_name'}})->message_ok;
$active_symbols = decode_json($t->message->[1]);
ok($active_symbols->{active_symbols});
ok($active_symbols->{active_symbols}->{"Random 50 Index"});

# test contracts_for
$t = $t->send_ok({json => {contracts_for => 'R_50'}})->message_ok;
my $contracts_for = decode_json($t->message->[1]);
ok($contracts_for->{contracts_for});
ok($contracts_for->{contracts_for}->{available});

# test offerings
$t = $t->send_ok({json => {offerings => {'symbol' => 'R_50'}}})->message_ok;
my $offerings = decode_json($t->message->[1]);
ok($offerings->{offerings});
ok($offerings->{offerings}->{hit_count});

# test offerings
$t = $t->send_ok({json => {trading_times => {'date' => Date::Utility->new->date_ddmmmyyyy}}})->message_ok;
my $trading_times = decode_json($t->message->[1]);
diag Dumper($trading_times);
ok($trading_times->{trading_times});

$t->finish_ok;

done_testing();
