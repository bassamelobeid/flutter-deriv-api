#!perl

use strict;
use warnings;
use Test::More;
use Data::Dumper;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;

build_test_R_50_data();

my $t = build_mojo_test();

$t->send_ok({json => {ticks => 'R_50'}})->message_ok;
$t->send_ok({json => {ticks => 'R_50'}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'AlreadySubscribed';

done_testing();
