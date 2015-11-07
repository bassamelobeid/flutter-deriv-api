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
my @ticks;
my %ticks;

for (1..50) {
    $t->send_ok({json => {ticks => 'R_50'}});
    while (1) {
        $t->message_ok;
        diag $t->message->[1];
        my $m = JSON::from_json $t->message->[1];
        is $m->{msg_type}, 'tick', 'got msg_type tick';
        ok $m->{tick}->{id}, 'got id';
        unless (exists $ticks{$m->{tick}->{id}}) {
            push @ticks, $m;
            $ticks{$m->{tick}->{id}} = $m;
            last;
        }
    }
}

alarm 10;
diag 'triggering resource error now';

my $emsg;
my $lastid;
$t->send_ok({json => {ticks => 'R_50'}});
while (1) {
    $t->message_ok;
    diag $t->message->[1];
    my $m = JSON::from_json $t->message->[1];
    if ($m->{msg_type} eq 'tick') {
        ok $m->{tick}->{id}, 'got id';
        unless (exists $ticks{$m->{tick}->{id}}) {
            push @ticks, $m;
            $ticks{$m->{tick}->{id}} = $m;
            $lastid = $m->{tick}->{id};
            last if $emsg;
        }
    } else {
        $emsg = $m;
        last if $lastid;
    }
}

ok $emsg->{error}, 'got an error message';
is $emsg->{error}->{code}, 'EndOfTickStream', 'EndOfTickStream';
is $emsg->{error}->{details}->{id}, $ticks[0]->{tick}->{id}, 'first opened stream has been canceled';

$t->finish_ok;

done_testing();
