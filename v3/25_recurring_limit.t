#!perl

use strict;
use warnings;
use Test::More;
use Data::Dumper;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Platform::RedisReplicated;

my $t = build_wsapi_test();

$t->send_ok({json => {ticks => 'R_50'}});
BOM::Platform::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998048;443.6823;');
$t->send_ok({json => {ticks => 'R_50'}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'AlreadySubscribed';

done_testing();
