#!perl

use strict;
use warnings;
use Test::More;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use BOM::System::RedisReplicated;

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
$t->finish_ok;

done_testing();
