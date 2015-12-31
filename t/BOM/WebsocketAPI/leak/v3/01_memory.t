use strict;
use warnings;

use JSON;
use JSON::Schema;
use File::Slurp;
use Mojo::JSON;
use Test::Mojo;
use Test::Most;
use Data::Dumper;

use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use TestHelper qw/test_schema build_mojo_test ws_connection_ok/;
use Test::NoLeaks;

# construct application outside of leak-detection code,
# becasue we don't measure leaks on that stage
my $t = Test::Mojo->new('BOM::WebSocketAPI');
ok($t);

sub might_leak {
    ws_connection_ok($t);
    $t->send_ok({json => {active_symbols => 'brief'}})->message_ok;
    my $res = decode_json($t->message->[1]);
    ok $res->{active_symbols};
    is $res->{msg_type}, 'active_symbols';
    test_schema('active_symbols', $res);

    $t->send_ok({json => {asset_index => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{asset_index};
    is $res->{msg_type}, 'asset_index';
    test_schema('asset_index', $res);
    $t->finish_ok(1000);
}

test_noleaks (
  code          => \&might_leak,
  track_memory  => 1,
  track_fds     => 1,
  passes        => 100,
  warmup_passes => 1,
  tolerate_hits => 0,
);

done_testing;
