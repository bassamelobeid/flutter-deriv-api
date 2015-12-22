package BOM::Test::LoadTester;

use strict;
use warnings;

use JSON;
use JSON::Schema;
use File::Slurp;
use Test::Mojo;
use Test::Most;
use Devel::Gladiator qw(walk_arena arena_ref_counts arena_table);
use Sys::MemInfo qw(totalmem freemem totalswap);

sub load_test {
    my $func = shift;

    # take snapshot of memory before executing
    my $free_memory = (&freemem / 1024);
    my $free_swap   = (Sys::MemInfo::get("freeswap") / 1024);

    # check for redis (Application)
    my $app_count = `netstat -nat | grep 6381 | grep EST |  wc -l`;
    $app_count = $app_count / 2;

    # check for redis (Local)
    my $local_count = `netstat -nat | grep 6379 | grep EST |  wc -l`;
    $local_count = $local_count / 2;

    my %dump1 = map { ("$_" => $_) } walk_arena();

    #start executing function now
    $func->();

    # take snapshot of memory after executing
    my $new_app_count = `netstat -nat | grep 6381 | grep EST |  wc -l`;
    $new_app_count = $new_app_count / 2;
    is $new_app_count, $app_count, 'Application redis connection is not leaked';

    my $new_local_count = `netstat -nat | grep 6379 | grep EST |  wc -l`;
    $new_local_count = $new_local_count / 2;
    is $new_local_count, $local_count, 'Local redis connection is not leaked';

    my %dump2 = map { $dump1{$_} ? () : ("$_" => $_) } walk_arena();
    use Devel::Peek;
    Dump \%dump2;

    my $current_mem  = (&freemem / 1024);
    my $current_swap = (Sys::MemInfo::get("freeswap") / 1024);

    is $current_mem,  $free_memory, 'Free memory ok after process';
    is $current_swap, $free_swap,   'Free swap memory ok after process';

    return;
}

1;
