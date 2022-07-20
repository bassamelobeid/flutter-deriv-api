use strict;
use warnings;
# Dump all the information in the current process table
use Proc::ProcessTable;

my $t = Proc::ProcessTable->new;

foreach my $p (@{$t->table}) {
    print "--------------------------------\n";
    next unless $p->{cmnd} =~ /rpc_redis/;
    foreach my $f ($t->fields){
        print $f, ":  ", $p->{$f}, "\n";
    }
}
