#!perl

use strict;
use warnings;
use Test::More;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use BOM::System::RedisReplicated;
use BOM::Feed::Populator::InsertTicks;
use BOM::Feed::Buffer::TickFile;
use File::Temp;
use Date::Utility;

my $now = Date::Utility->new('2012-03-14');
my $work_dir = File::Temp->newdir();
my $buffer = BOM::Feed::Buffer::TickFile->new(base_dir => "$work_dir");
my  $fill_start = $now->minus_time_interval('1d7h');
my $populator  = BOM::Feed::Populator::InsertTicks->new({
     symbols            => [qw/ frxUSDJPY /],
     last_migrated_time => $fill_start,
     buffer             => $buffer,
});

my $fh;
open($fh, "<", "/home/git/regentmarkets/bom-test/feed/combined/frxUSDJPY/13-Apr-12.fullfeed") or die $!;
my  @ticks = <$fh>;
close $fh;
foreach my $i (0 .. 1) {
    $populator->insert_to_db({
                ticks  => \@ticks,
                date   => $fill_start->plus_time_interval("${i}d"),
                symbol => 'frxUSDJPY',
            });
        }


my $t = build_mojo_test();

$t->send_ok({json => {ticks => 'R_50'}});
BOM::System::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998048;443.6823;');
$t->send_ok({json => {ticks => 'R_50'}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'AlreadySubscribed';

$t->send_ok({json => {forget_all => 'ticks'}});
$t = $t->message_ok;
my $m = JSON::from_json($t->message->[1]);
ok $m->{forget_all} or diag explain $m;
is scalar(@{$m->{forget_all}}), 1;
test_schema('forget_all', $m);

my $start = $now->plus_time_interval('1h');
my $end = $start->plus_time_interval('30m');

$t->send_ok({json => {ticks_history => 'frxUSDJPY', style => 'candles',  granularity   => 60, end => $end->epoch, start => $start->epoch}});
BOM::System::RedisReplicated::redis_write->publish('FEED::frxUSDJPY', 'R_50;1334251800;7746.0253;60:7747.4457,7747.7367,7745.8114,7746.0253;120:7747.4457,7747.7367,7745.8114,7746.0253;180:7753.0015,7753.0015,7744.7663,7746.0253;300:7747.4457,7747.7367,7745.8114,7746.0253;600:7747.4457,7747.7367,7745.8114,7746.0253;900:7745.6369,7753.4174,7736.7159,7746.0253;1800:7745.6369,7753.4174,7736.7159,7746.0253;3600:7745.6369,7753.4174,7736.7159,7746.0253;7200:7708.404,7753.4174,7673.6985,7746.0253;14400:7708.404,7753.4174,7673.6985,7746.0253;28800:7655.499,7753.4174,7595.7156,7746.0253;86400:7655.499,7753.4174,7595.7156,7746.0253;');
$t->send_ok({json => {ticks_history => 'frxUSDJPY',  style => 'candles',  granularity   => 60, end => $end->epoch, start => $start->epoch }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'AlreadySubscribed';

$t->send_ok({json => {forget_all => 'candles'}});
$t = $t->message_ok;
$m = JSON::from_json($t->message->[1]);
ok $m->{forget_all} or diag explain $m;
is scalar(@{$m->{forget_all}}), 1;
test_schema('forget_all', $m);
$t->finish_ok;
done_testing();
