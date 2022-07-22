use strict;
use warnings;
# Dump all the information in the current process table
use Proc::ProcessTable;
use DataDog::DogStatsd::Helper qw(stats_gauge);
use feature qw(state);
dd_memory(1,'forex');
sleep 10;
dd_memory(0, 'forex');
sub dd_memory{
    my ($start, $market) = @_;
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
            # TODO when finish, this process will no there, so we must process it before kill
            regexp => qr/proposal_sub.pl/,
            dd_prefix => 'memory.proposal_sub'
        },

    );
    state %data;
    if($start){
        %data = ();
    }
    # sort to keep them same order
    my @processes = sort {$a->{pid} <=> $b->{pid}} $t->table->@*;
    foreach my $cfg_idx (0..$#process_cfg){
        my $cfg = $process_cfg[$cfg_idx];
        # the idx of processes that have same name
        my $idx = 0;
        foreach my $p (@processes) {
            next unless $p->{cmndline} =~ $cfg->{regexp};
            next if ($cfg->{ppid} // '') eq 'not 1' && $p->{ppid} != 1;
            $idx++;
            print "$p->{cmndline}:$p->{pid}\n";
            foreach my $f (qw(size rss)){
                stats_gauge("$cfg->{dd_prefix}.$f", $p->{$f}, {tags => ["tag:idx$idx", "tag:$market"]});
                if($start){
                    $data{$cfg_idx}{$f}{$idx}{start} = $p->{$f};
                }
                else{
                    stats_gauge("$cfg->{dd_prefix}.${f}delta", $p->{$f} - $data{$cfg_idx}{$f}{$idx}{start}, {tags => ["tag:idx$idx", "tag:$market"]});
                }
            }
        }
    }
}
