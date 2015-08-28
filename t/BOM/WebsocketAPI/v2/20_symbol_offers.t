use strict;
use warnings;
use Test::More;
use Test::Mojo;
use JSON::Schema;
use File::Slurp;
use JSON;
use Data::Dumper;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange');
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

my $config_dir = "config/v1";

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
$t = $t->send_ok({json => {contracts_for =>  'R_50'}})->message_ok;
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
ok($trading_times->{trading_times});
ok($trading_times->{trading_times}->{markets});

$t->finish_ok;

done_testing();
