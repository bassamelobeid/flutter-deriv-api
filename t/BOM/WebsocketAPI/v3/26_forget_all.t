#!perl

use strict;
use warnings;
use Test::More;
use Test::MockTime qw/:all/;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use BOM::System::RedisReplicated;
use BOM::Populator::InsertTicks;
use BOM::Populator::TickFile;
use File::Temp;
use Date::Utility;

my $now = Date::Utility->new('2016-05-13 00:00:00');
set_fixed_time($now->epoch);
my $work_dir = File::Temp->newdir();
$ENV{BOM_POPULATOR_ROOT} = "$work_dir";

my $buffer     = BOM::Populator::TickFile->new(base_dir => "$work_dir");
my $fill_start = $now;
my $populator  = BOM::Populator::InsertTicks->new({
    symbols            => [qw/ frxUSDJPY /],
    last_migrated_time => $fill_start,
    buffer             => $buffer,
});

my $fh;
# Just to insert dummy tick
open($fh, "<", "/home/git/regentmarkets/bom-test/feed/combined/frxUSDJPY/13-Apr-12.fullfeed") or die $!;
my @ticks = <$fh>;
close $fh;
$populator->insert_to_db({
    ticks  => \@ticks,
    date   => $fill_start,
    symbol => 'frxUSDJPY',
});

my $t = build_mojo_test();

$t->send_ok({json => {ticks => 'R_50'}});

# waiting to avoid to process next message first
Mojo::IOLoop->one_tick for (1 .. 5);

$t->send_ok({
        json => {
            ticks  => 'R_50',
            req_id => 123
        }})->message_ok;
my $res = decode_json($t->message->[1]);
ok $res->{echo_req};
is $res->{req_id}, 123;
is $res->{error}->{code}, 'AlreadySubscribed', 'Already subscribed for tick';

$t->send_ok({json => {forget_all => 'ticks'}});
$t = $t->message_ok;
my $m = JSON::from_json($t->message->[1]);
ok $m->{forget_all}, "Manage to forget_all: ticks" or diag explain $m;
is scalar(@{$m->{forget_all}}), 1, "Forget the relevant tick channel";
test_schema('forget_all', $m);

my $start = $now;
my $end   = $start->plus_time_interval('30m');
$t->send_ok({
        json => {
            ticks_history => 'frxUSDJPY',
            style         => 'candles',
            granularity   => 60,
            end           => $end->epoch,
            start         => $start->epoch,
            subscribe     => 1
        }});
Mojo::IOLoop->one_tick for (1 .. 5);
$t->send_ok({
        json => {
            ticks_history => 'frxUSDJPY',
            style         => 'candles',
            granularity   => 60,
            end           => $end->epoch,
            start         => $start->epoch,
            subscribe     => 1
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'AlreadySubscribed', 'Already subscribed for candles';

$t->send_ok({json => {forget_all => 'candles'}});
$t = $t->message_ok;
$m = JSON::from_json($t->message->[1]);
ok $m->{forget_all}, "Manage to forget_all: candles" or diag explain $m;
is scalar(@{$m->{forget_all}}), 1, "Forget the relevant candle feed channel";
test_schema('forget_all', $m);
$t->send_ok({
        json => {
            ticks_history => 'frxUSDJPY',
            style         => 'candles',
            granularity   => 60,
            end           => $end->epoch,
            start         => $start->epoch,
            subscribe     => 1
        }})->message_ok;
$m = JSON::from_json($t->message->[1]);
ok $m->{candles}, "Manage to get candles" or diag explain $m;
$t->finish_ok;
done_testing();
