package BOM::Test::RPC::BinaryRpcRedis;

use strict;
use warnings;

my $pid;

BEGIN {
    $pid = fork;
    if (not defined $pid) {
        die 'Could not fork process to start RPC: ' . $!;
    } elsif ($pid == 0) {
        local $ENV{NO_PURGE_REDIS} = 1;

        my $script = '/home/git/regentmarkets/bom-test/bin/binary_rpc_redis_for_test.pl';

        exec($^X, qw(-MBOM::Test), $script) or die "Couldn't execute $script: $!";
    }
}

END {
    if ($pid) {
        print "Stopping test RPC server ($pid)...\n";
        kill HUP => $pid;
    }
}

1;
