#!/usr/bin/perl

use strict;
use warnings;

use JSON;
use JSON::Schema;
use File::Slurp;
use Test::Mojo;
use Test::Most;
use Data::Dumper;
use Devel::Gladiator qw(walk_arena arena_ref_counts arena_table);
use Sys::MemInfo qw(totalmem freemem totalswap);

my $connections = 2;

my $free_memory = (&freemem / 1024);
my $free_swap   = (Sys::MemInfo::get("freeswap") / 1024);

my $app_count = `netstat -nat | grep 6381 | grep EST |  wc -l`;
$app_count = $app_count / 2;
print "Current Application Redis connection count is " . $app_count . "\n";

my $local_count = `netstat -nat | grep 6379 | grep EST |  wc -l`;
$local_count = $local_count / 2;
print "Current Local Redis connection count is " . $local_count . "\n";

my %dump1 = map { ("$_" => $_) } walk_arena();

sub strip_doc_send {
    my $data = shift;
    my $r;
    for my $p (keys %{$data->{properties}}) {
        $r->{$p} = $data->{properties}->{$p}->{sample} // {};
    }
    return $r;
}

my $svr     = $ENV{BOM_WEBSOCKETS_SVR} || '';
my $counter = 0;
my @pool    = ();
while ($counter < $connections) {
    my $t = $svr ? Test::Mojo->new : Test::Mojo->new('BOM::WebSocketAPI');
    $t->websocket_ok("$svr/websockets/v3");
    my $send = strip_doc_send(JSON::from_json(File::Slurp::read_file("config/v3/active_symbols/example.json")));
    $t->send_ok({json => $send}, "send request for active_symbols");
    $t->message_ok("active_symbols got a response");

    my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("config/v3/active_symbols/receive.json")));
    my $result    = $validator->validate(Mojo::JSON::decode_json $t->message->[1]);
    ok $result, "active_symbols response is valid";
    if (not $result) { print " - $_\n" foreach $result->errors; print Data::Dumper::Dumper(Mojo::JSON::decode_json $t->message->[1]) }
    push @pool, $t;
    $counter++;
}

foreach my $conn (@pool) {
    $conn->finish_ok;
}

my $new_app_count = `netstat -nat | grep 6381 | grep EST |  wc -l`;
$new_app_count = $new_app_count / 2;
print "Current Application Redis connection count is " . $new_app_count . "\n";

is $new_app_count, $app_count, 'Application redis connection is not leaked';

my $new_local_count = `netstat -nat | grep 6379 | grep EST |  wc -l`;
$new_local_count = $new_local_count / 2;
print "Current Local Redis connection count is " . $new_local_count . "\n";

is $new_local_count, $local_count, 'Local redis connection is not leaked';

my %dump2 = map { $dump1{$_} ? () : ("$_" => $_) } walk_arena();
use Devel::Peek;
Dump \%dump2;

my $current_mem  = (&freemem / 1024);
my $current_swap = (Sys::MemInfo::get("freeswap") / 1024);

is $current_mem,  $free_memory, 'Free memory ok after process';
is $current_swap, $free_swap,   'Free swap memory ok after process';

done_testing();

1;
