use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use Date::Utility;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use Test::MockModule;

use TestHelper qw/test_schema build_mojo_test/;

initialize_realtime_ticks_db();
use Finance::Asset;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD JPY);
my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch,
    quote      => 100,
});

my $t = build_mojo_test({language => 'EN'});

# test payout_currencies
$t = $t->send_ok({json => {payout_currencies => 1}})->message_ok;
my $payout_currencies = decode_json($t->message->[1]);
ok($payout_currencies->{payout_currencies});
ok(grep { $_ eq 'USD' } @{$payout_currencies->{payout_currencies}});
test_schema('payout_currencies', $payout_currencies);

# test active_symbols
my $rpc_caller = Test::MockModule->new('BOM::WebSocketAPI::CallingEngine');
my $call_params;
$rpc_caller->mock('call_rpc', sub { $call_params = $_[3], shift->send({json => {ok => 1}}) });
$t = $t->send_ok({json => {active_symbols => 'full'}})->message_ok;
ok exists $call_params->{token};
$rpc_caller->unmock_all;

$t = $t->send_ok({json => {active_symbols => 'full'}})->message_ok;
my $active_symbols = decode_json($t->message->[1]);
is($active_symbols->{msg_type}, 'active_symbols');
ok($active_symbols->{active_symbols});
test_schema('active_symbols', $active_symbols);

$t = $t->send_ok({json => {active_symbols => 'brief'}})->message_ok;
$active_symbols = decode_json($t->message->[1]);
ok($active_symbols->{active_symbols});
test_schema('active_symbols', $active_symbols);

# test contracts_for
$t = $t->send_ok({json => {contracts_for => 'R_50'}})->message_ok;
my $contracts_for = decode_json($t->message->[1]);
is($contracts_for->{msg_type}, 'contracts_for');
ok($contracts_for->{contracts_for});
ok($contracts_for->{contracts_for}->{available});
is($contracts_for->{contracts_for}->{feed_license}, 'realtime', 'Correct license for contracts_for');
test_schema('contracts_for', $contracts_for);
if (not $now->is_a_weekend) {
# test contracts_for japan
    $t = $t->send_ok({
            json => {
                contracts_for => 'frxUSDJPY',
                region        => 'japan'
            }})->message_ok;
    my $contracts_for_japan = decode_json($t->message->[1]);
    ok($contracts_for_japan->{contracts_for});
    ok($contracts_for_japan->{contracts_for}->{available});
    is($contracts_for->{contracts_for}->{feed_license}, 'realtime', 'Correct license for contracts_for');
    test_schema('contracts_for', $contracts_for_japan);
}
$t = $t->send_ok({json => {trading_times => Date::Utility->new->date_yyyymmdd}})->message_ok;
my $trading_times = decode_json($t->message->[1]);
ok($trading_times->{msg_type}, 'trading_times');
ok($trading_times->{trading_times});
ok($trading_times->{trading_times}->{markets});
test_schema('trading_times', $trading_times);

Cache::RedisDB->flushall;
$rpc_caller = Test::MockModule->new('BOM::WebSocketAPI::CallingEngine');
$rpc_caller->mock('call_rpc', sub { $call_params = $_[3], shift->send({json => {ok => 1}}) });
$t = $t->send_ok({json => {asset_index => 1}})->message_ok;
is $call_params->{language}, 'EN';
$rpc_caller->unmock_all;

$t = $t->send_ok({json => {asset_index => 1}})->message_ok;
my $asset_index = decode_json($t->message->[1]);
is($asset_index->{msg_type}, 'asset_index');
ok($asset_index->{asset_index});
my $got_asset_index = $asset_index->{asset_index};
test_schema('asset_index', $asset_index);

$rpc_caller->mock('call_rpc', sub { $call_params = $_[3], shift->send({json => {ok => 1}}) });
$t = $t->send_ok({json => {asset_index => 1}})->message_ok;
is_deeply $got_asset_index, $asset_index->{asset_index}, 'Should use cache';
$rpc_caller->unmock_all;

$t->finish_ok;

done_testing();
