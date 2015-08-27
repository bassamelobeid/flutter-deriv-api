use strict;
use warnings;
use Test::More;
use Test::Mojo;
use FindBin qw/$Bin/;
use JSON::Schema;
use File::Slurp;
use JSON;
use Data::Dumper;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $t = Test::Mojo->new('BOM::WebSocketAPI');
$t->websocket_ok("/websockets/contracts");

my $config_dir = "$Bin/../config/v1";

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

# not working under TRAVIS
unless ($ENV{TRAVIS}) {
    # test contracts_for
    $t = $t->send_ok({json => {contracts_for => {symbol: 'R_50'}}})->message_ok;
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
}

$t->finish_ok;

done_testing();
