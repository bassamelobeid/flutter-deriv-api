use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::MockTime qw/:all/;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use File::Temp;
use Date::Utility;

use BOM::Platform::RedisReplicated;
use BOM::Test::Data::Utility::FeedTestDatabase;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_50',
    epoch      => Date::Utility->new->epoch,
    quote      => 100
});

sub _create_tick {    #creates R_50 tick in redis channel FEED::R_50
    my ($i, $symbol) = @_;
    $i ||= 700;
    BOM::Platform::RedisReplicated::redis_write->publish("FEED::$symbol",
              "$symbol;"
            . Date::Utility->new->epoch . ';'
            . $i
            . ';60:7807.4957,7811.9598,7807.1055,7807.1055;120:7807.0929,7811.9598,7806.6856,7807.1055;180:7793.6775,7811.9598,7793.5814,7807.1055;300:7807.0929,7811.9598,7806.6856,7807.1055;600:7807.0929,7811.9598,7806.6856,7807.1055;900:7789.5519,7811.9598,7784.1465,7807.1055;1800:7789.5519,7811.9598,7784.1465,7807.1055;3600:7723.5128,7811.9598,7718.4277,7807.1055;7200:7723.5128,7811.9598,7718.4277,7807.1055;14400:7743.3676,7811.9598,7672.4463,7807.1055;28800:7743.3676,7811.9598,7672.4463,7807.1055;86400:7743.3676,7811.9598,7672.4463,7807.1055;'
    );
}

my $t = build_wsapi_test();

# both these subscribtion should work as req_id is different
$t->send_ok({json => {ticks => 'R_50'}});
$t->send_ok({
        json => {
            ticks  => 'R_50',
            req_id => 1
        }});
my $pid = fork;
die "Failed fork for testing 'ticks' WS API call: $@" unless defined $pid;
unless ($pid) {
    sleep 1;
    _create_tick(700, 'R_50');
    sleep 1;
    exit;
}

my ($res, $ticks, @ids);
for (my $i = 0; $i < 2; $i++) {
    $t->message_ok;
    $res = decode_json($t->message->[1]);
    push @ids, $res->{tick}->{id};
    $ticks->{$res->{tick}->{symbol}}++;
}

$t->send_ok({json => {forget_all => 'ticks'}});
$t   = $t->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{forget_all}, "Manage to forget_all: ticks" or diag explain $res;
is scalar(@{$res->{forget_all}}), 2, "Forget the relevant tick channel";

@ids = sort @ids;
my @forget_ids = sort @{$res->{forget_all}};
cmp_bag(\@ids, \@forget_ids, 'correct forget ids for ticks');

$t->send_ok({
        json => {
            ticks_history => 'R_50',
            end           => "latest",
            count         => 10,
            style         => "candles",
            subscribe     => 1
        }});

$t->send_ok({
        json => {
            ticks_history => 'R_50',
            end           => "latest",
            count         => 10,
            style         => "candles",
            subscribe     => 1,
            req_id        => 1
        }});

$pid = fork;
die "Failed fork for testing 'ticks' WS API call: $@" unless defined $pid;
unless ($pid) {
    sleep 1;
    _create_tick(701, 'R_50');
    sleep 1;
    exit;
}

for (my $i = 0; $i < 2; $i++) {
    $t->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{msg_type}, "candles", 'correct message type';
}

@ids = ();
for (my $j = 0; $j < 2; $j++) {
    $t->message_ok;
    $res = decode_json($t->message->[1]);
    push @ids, $res->{ohlc}->{id};
    is $res->{msg_type}, "ohlc", 'correct message type';
}

$t->send_ok({json => {forget_all => 'candles'}});
$t   = $t->message_ok;
$res = JSON::from_json($t->message->[1]);
ok $res->{forget_all}, "Manage to forget_all: candles" or diag explain $res;
is scalar(@{$res->{forget_all}}), 2, "Forget the relevant candle feed channel";
test_schema('forget_all', $res);

@forget_ids = sort @{$res->{forget_all}};
cmp_bag(\@ids, \@forget_ids, 'correct forget ids for ticks history');

$t->finish_ok;

done_testing();
