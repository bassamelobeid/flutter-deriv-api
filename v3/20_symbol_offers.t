use strict;
use warnings;
use Test::More;
use Test::Deep qw( cmp_deeply );
use JSON;
use Data::Dumper;
use Date::Utility;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods);
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use Test::MockModule;

use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client/;

initialize_realtime_ticks_db();
use Finance::Asset;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD JPY);
my $now = Date::Utility->new;
generate_trading_periods('frxUSDJPY');
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

generate_trading_periods('frxEURUSD');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxEURUSD',
        recorded_date => $now
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxEURUSD',
    epoch      => $now->epoch,
    quote      => 100,
});

my $t = build_wsapi_test({language => 'EN'});

# test payout_currencies
$t = $t->send_ok({json => {payout_currencies => 1}})->message_ok;
my $payout_currencies = decode_json($t->message->[1]);
ok($payout_currencies->{payout_currencies});
ok(grep { $_ eq 'USD' } @{$payout_currencies->{payout_currencies}});
test_schema('payout_currencies', $payout_currencies);

# test active_symbols
my (undef, $call_params) = call_mocked_client($t, {active_symbols => 'full'});
ok exists $call_params->{token};

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
                product_type  => 'multi_barrier'
            }})->message_ok;
    my $contracts_for_japan = decode_json($t->message->[1]);
    ok($contracts_for_japan->{contracts_for});
    ok($contracts_for_japan->{contracts_for}->{available});
    is($contracts_for->{contracts_for}->{feed_license}, 'realtime', 'Correct license for contracts_for');
    test_schema('contracts_for', $contracts_for_japan);

# test contracts_for EURUSD for forward_starting_options
    my $expected_blackouts = [
          [
            '11:00:00',
            '13:00:00'
          ],
          [
            '20:00:00',
            '23:59:59'
          ]
        ];

    $t = $t->send_ok({
            json => {
                contracts_for => 'frxEURUSD',
            }})->message_ok;
    my $contracts_for_eurusd = decode_json($t->message->[1]);
    ok($contracts_for_eurusd->{contracts_for});
    ok($contracts_for_eurusd->{contracts_for}->{available});
    is($contracts_for_eurusd->{contracts_for}->{feed_license}, 'realtime', 'Correct license for contracts_for');

    foreach my $contract (@{$contracts_for_eurusd->{contracts_for}->{'available'}}){
      next if $contract->{'start_type'} ne 'forward';
      cmp_deeply $contract->{'forward_starting_options'}[0]{'blackouts'}, $expected_blackouts, "expected blackouts";
    }

    test_schema('contracts_for', $contracts_for_eurusd);
}

$t = $t->send_ok({json => {trading_times => Date::Utility->new->date_yyyymmdd}})->message_ok;
my $trading_times = decode_json($t->message->[1]);
ok($trading_times->{msg_type}, 'trading_times');
ok($trading_times->{trading_times});
ok($trading_times->{trading_times}->{markets});
test_schema('trading_times', $trading_times);

Cache::RedisDB->flushall;
(undef, $call_params) = call_mocked_client($t, {asset_index => 1});
is $call_params->{language}, 'EN';

$t = $t->send_ok({json => {asset_index => 1}})->message_ok;
my $asset_index = decode_json($t->message->[1]);
is($asset_index->{msg_type}, 'asset_index');
ok($asset_index->{asset_index});
my $got_asset_index = $asset_index->{asset_index};
test_schema('asset_index', $asset_index);

(undef, $call_params) = call_mocked_client($t, {asset_index => 1});
is_deeply $got_asset_index, $asset_index->{asset_index}, 'Should use cache';

$t->finish_ok;

done_testing();
