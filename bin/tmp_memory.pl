use strict;
use warnings;
# Dump all the information in the current process table
use Proc::ProcessTable;
use DataDog::DogStatsd::Helper qw(stats_gauge);
dd_memory();
sub dd_memory{
    my $t = Proc::ProcessTable->new;
    #my @fields = $t->fields;
    #print "@fields\n";
    my @process_cfg = (
        {
            regexp => qr/binary_rpc_redis\.pl.*category=general/,
            dd_prefix => 'memory.rpc_redis_general'
        },
        {
            regexp => qr/binary_rpc_redis\.pl.*category=tick/,
            dd_prefix => 'memory.rpc_redis_tick'
        },
        {
            regexp => qr/price_queue\.pl/,
            dd_prefix => 'memory.price_queue',
        },
        {
            regexp => qr/price_daemon\.pl/,
            dd_prefix => 'memory.price_daemon',
            ppid => 'not 1', # price_daemon will fork a subprocess as a worker, the parent process does nothing, so ignore it.
        },
        {
            regexp => qr/pricer_load_runner\.pl/,
            dd_prefix => 'memory.pricer_load_runner'
        },
        {
            regexp => qr/proposal_sub.pl/,
            dd_prefix => 'memory.proposal_sub'
        },

    );
    foreach my $p (@{$t->table}) {
        foreach my $cfg (@process_cfg){
            next unless $p->{cmndline} =~ $cfg->{regexp};
            next if ($cfg->{ppid} // '') eq 'not 1' && $p->{ppid} != 1;
            $cfg->{idx}++;
            print "$p->{cmndline}:$p->{pid}\n";
            foreach my $f (qw(size rss)){
                stats_gauge("$cfg->{dd_prefix}.$f", $p->{$f}, {tags => ["tag:$cfg->{idx}"]});
            }
        }
    }
}
