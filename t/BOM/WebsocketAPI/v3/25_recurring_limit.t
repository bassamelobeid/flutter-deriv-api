#!perl

use strict;
use warnings;
use Test::More;
use Data::Dumper;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;

my $req = {
    json => {
        "proposal"      => 1,
        "amount"        => "10",
        "basis"         => "payout",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "symbol"        => "R_50",
        "duration"      => "2",
        "duration_unit" => "m"
    }};

build_test_R_50_data();

my $t = build_mojo_test();
my @ticks;
my %ticks;

for (1..50) {
    $t->send_ok($req);
    while (1) {
        $t->message_ok;
        diag $t->message->[1];
        my $m = JSON::from_json $t->message->[1];
        is $m->{msg_type}, 'proposal', 'got msg_type proposal';
        ok $m->{proposal}->{id}, 'got id';
        unless (exists $ticks{$m->{proposal}->{id}}) {
            push @ticks, $m;
            $ticks{$m->{proposal}->{id}} = $m;
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
    } elsif ($m->{msg_type} eq 'proposal') {
        ok $m->{proposal}->{id}, 'got id';
    } else {
        $emsg = $m;
        last if $lastid;
    }
}

ok $emsg->{error}, 'got an error message';
is $emsg->{error}->{code}, 'EndOfStream', 'EndOfStream';
is $emsg->{error}->{details}->{id}, $ticks[0]->{proposal}->{id}, 'first opened stream has been canceled';

$t->finish_ok;

done_testing();
