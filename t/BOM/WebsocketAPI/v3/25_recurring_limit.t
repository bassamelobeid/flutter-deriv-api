#!perl

use strict;
use warnings;
use Test::More;
use Data::Dumper;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use BOM::System::Chronicle;

my $t = build_mojo_test();

$t->send_ok({json => {ticks => 'R_50'}});
sleep 1;
BOM::System::Chronicle->_redis_write->publish('FEED::R_50', 'R_50;1447998048;443.6823;60:443.4932,443.7978,443.4932,443.6823;120:443.4932,443.7978,443.4932,443.6823;180:443.8093,443.8093,443.4128,443.6823;300:443.4932,443.7978,443.4932,443.6823;600:443.4932,443.7978,443.4932,443.6823;900:444.446,444.5547,443.4128,443.6823;1800:444.446,444.5547,443.4128,443.6823;3600:445.4323,446.112,443.4128,443.6823;7200:445.093,446.7221,443.4128,443.6823;14400:445.093,446.7221,443.4128,443.6823;28800:446.5887,447.472,442.3138,443.6823;86400:446.5887,447.472,442.3138,443.6823;;out:1447998048.02848');
$t->send_ok({json => {ticks => 'R_50'}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'AlreadySubscribed';

done_testing();
