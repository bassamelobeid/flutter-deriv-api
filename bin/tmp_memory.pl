use strict;
use warnings;
# Dump all the information in the current process table
use Proc::ProcessTable;

my $t = Proc::ProcessTable->new;

foreach my $p (@{$t->table}) {
    print "--------------------------------\n";
    foreach my $f ($t->fields){
        print $f, ":  ", $p->{$f}, "\n";
    }
}
