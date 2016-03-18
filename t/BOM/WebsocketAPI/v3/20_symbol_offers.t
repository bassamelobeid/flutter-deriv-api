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
use TestHelper qw/test_schema build_mojo_test/;

initialize_realtime_ticks_db();
use Finance::Asset;
use BOM::Product::Contract::Finder::Japan qw(available_contracts_for_symbol);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD JPY);
my $now = Date::Utility->new('2015-08-21 05:30:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                underlying => 'frxUSDJPY',
                epoch      => Date::Utility->new($_)->epoch,
                quote      => 100,
            })
            for (
            "2015-01-01 00:00:00",  "2015-07-01 00:00:00", "2015-08-03 00:00:00",          "2015-08-17 00:00:00", "2015-08-21 00:00:00",
            "2015-08-21 00:45:00", "2015-08-21 03:45:00", "2015-08-21 04:45:00", "2015-08-21 05:30:00"
            );

my $f = available_contracts_for_symbol({
    symbol => 'frxUSDJPY',
    date   => $now,
});

my $t = build_mojo_test();

# test payout_currencies
$t = $t->send_ok({json => {payout_currencies => 1}})->message_ok;
my $payout_currencies = decode_json($t->message->[1]);
ok($payout_currencies->{payout_currencies});
ok(grep { $_ eq 'USD' } @{$payout_currencies->{payout_currencies}});
test_schema('payout_currencies', $payout_currencies);

# test active_symbols
$t = $t->send_ok({json => {active_symbols => 'full'}})->message_ok;
my $active_symbols = decode_json($t->message->[1]);
ok($active_symbols->{active_symbols});
test_schema('active_symbols', $active_symbols);

$t = $t->send_ok({json => {active_symbols => 'brief'}})->message_ok;
$active_symbols = decode_json($t->message->[1]);
ok($active_symbols->{active_symbols});
test_schema('active_symbols', $active_symbols);

# test contracts_for
$t = $t->send_ok({json => {contracts_for => 'R_50'}})->message_ok;
my $contracts_for = decode_json($t->message->[1]);
ok($contracts_for->{contracts_for});
ok($contracts_for->{contracts_for}->{available});
is($contracts_for->{contracts_for}->{feed_license}, 'realtime', 'Correct license for contracts_for');
test_schema('contracts_for', $contracts_for);
# test contracts_for japan
$t = $t->send_ok({
        json => {
            contracts_for => 'frxUSDJPY',
            region        => 'japan'
        }})->message_ok;
print Data::Dumper::Dumper($contracts_for_japan->{contracts_for}->{available});
my $contracts_for_japan = decode_json($t->message->[1]);
ok($contracts_for_japan->{contracts_for});
ok($contracts_for_japan->{contracts_for}->{available});
is($contracts_for->{contracts_for}->{feed_license}, 'realtime', 'Correct license for contracts_for');
test_schema('contracts_for', $contracts_for_japan);

$t = $t->send_ok({json => {trading_times => Date::Utility->new->date_yyyymmdd}})->message_ok;
my $trading_times = decode_json($t->message->[1]);
ok($trading_times->{trading_times});
ok($trading_times->{trading_times}->{markets});
test_schema('trading_times', $trading_times);

$t = $t->send_ok({json => {asset_index => 1}})->message_ok;
my $asset_index = decode_json($t->message->[1]);
ok($asset_index->{asset_index});
test_schema('asset_index', $asset_index);

$t->finish_ok;

done_testing();
