use strict;
use warnings;
use Test::More;
use Test::Mojo;
use JSON::Schema;
use File::Slurp;
use JSON;
use Data::Dumper;
use Date::Utility;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

initialize_realtime_ticks_db();
use BOM::Market::UnderlyingDB;

my @underlying_symbols = BOM::Market::UnderlyingDB->instance->get_symbols_for(
    market            => 'indices',
    contract_category => 'ANY',
    broker            => 'VRT',
);
my @exchange = map { BOM::Market::Underlying->new($_)->exchange_name } @underlying_symbols;
push @exchange, ('RANDOM', 'FOREX','ODLS', 'RANDOM_NOCTURNE');
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(    # .. why isn't this in the testdb by default anyway?
    'exchange',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for @exchange;
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency',        {symbol => $_}) for qw(USD JPY);
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency_config', {symbol => $_}) for qw(USD JPY);
my $now = Date::Utility->new('2015-08-21 05:30:00');
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_flat',
    {
        symbol        => 'R_50',
        recorded_date => $now,
    });

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch,
    quote      => 100
});


my $t = build_mojo_test();

# test payout_currencies
$t = $t->send_ok({json => {payout_currencies => 1}})->message_ok;
my $payout_currencies = decode_json($t->message->[1]);
ok($payout_currencies->{payout_currencies});
ok(grep { $_ eq 'USD' } @{$payout_currencies->{payout_currencies}});
test_schema('payout_currencies', $payout_currencies);

# test active_symbols
$t = $t->send_ok({json => {active_symbols => 'symbol'}})->message_ok;
my $active_symbols = decode_json($t->message->[1]);
ok($active_symbols->{active_symbols});
ok($active_symbols->{active_symbols}->{R_50});
test_schema('active_symbols', $active_symbols);

$t = $t->send_ok({json => {active_symbols => 'display_name'}})->message_ok;
$active_symbols = decode_json($t->message->[1]);
ok($active_symbols->{active_symbols});
ok($active_symbols->{active_symbols}->{"Random 50 Index"});
test_schema('active_symbols', $active_symbols);

# test contracts_for
$t = $t->send_ok({json => {contracts_for => 'R_50'}})->message_ok;
my $contracts_for = decode_json($t->message->[1]);
ok($contracts_for->{contracts_for});
ok($contracts_for->{contracts_for}->{available});
test_schema('contracts_for', $contracts_for);
# test contracts_for japan
$t = $t->send_ok({
        json => {
            contracts_for => 'frxUSDJPY',
            region        => 'japan'
        }})->message_ok;
my $contracts_for_japan = decode_json($t->message->[1]);
ok($contracts_for_japan->{contracts_for});
ok($contracts_for_japan->{contracts_for}->{available});
test_schema('contracts_for', $contracts_for_japan);
# test offerings
$t = $t->send_ok({json => {offerings => {'symbol' => 'R_50'}}})->message_ok;
my $offerings = decode_json($t->message->[1]);
ok($offerings->{offerings});
ok($offerings->{offerings}->{hit_count});
test_schema('offerings', $offerings);
# test offerings
$t = $t->send_ok({json => {trading_times => {'date' => Date::Utility->new->date_ddmmmyyyy}}})->message_ok;
my $trading_times = decode_json($t->message->[1]);
ok($trading_times->{trading_times});
ok($trading_times->{trading_times}->{markets});
test_schema('trading_times', $trading_times);

$t->finish_ok;

done_testing();
