use strict;
use warnings;
# Dump all the information in the current process table
use Proc::ProcessTable;
dd_memory();
sub dd_memory{
    my $t = Proc::ProcessTable->new;

    my @process_cfg = (
        {
            regexp => qr/binary_rpc_redis\.pl.*category=general/,
            dd_prefix => 'memory.rpc_redis_general'
        },
        {
             regexp => qr/binary_rpc_redis\.pl.*category=general/,
            dd_prefix => 'memory.rpc_redis_general'
        },
    );
    foreach my $p (@{$t->table}) {
        foreach my $cfg (@process_cfg){
            next unless $p->{cmndline} =~ $cfg->{regexp};
            foreach my $f (qw(size rss)){
                print $f, ":  ", $p->{$f}, "\n";

            }
        }
    }
}
