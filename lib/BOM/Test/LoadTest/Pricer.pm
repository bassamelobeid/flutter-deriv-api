package BOM::Test::LoadTest::Pricer;
use strict;
use warnings;
use Proc::ProcessTable;
use DataDog::DogStatsd::Helper qw(stats_gauge);
use feature qw(state);
use Exporter 'import';
our @EXPORT_OK = qw(dd_memory_and_time);

sub dd_memory {
    my ($start_market) = @_;

    my $t = Proc::ProcessTable->new;
    #my @fields = $t->fields;
    #print "@fields\n";
    my $dd_prefix   = 'qaloadtest.memory';
    my @process_cfg = ({
            regexp    => qr/binary_rpc_redis\.pl.*category=general/,
            dd_prefix => "$dd_prefix.rpc_redis_general"
        },
        {
            regexp    => qr/binary_rpc_redis\.pl.*category=tick/,
            dd_prefix => "$dd_prefix.rpc_redis_tick"
        },
        {
            regexp    => qr/price_queue\.pl/,
            dd_prefix => "$dd_prefix.price_queue",
        },
        {
            regexp    => qr/price_daemon\.pl/,
            dd_prefix => "$dd_prefix.price_daemon",
            ppid      => 'not 1',                    # price_daemon will fork a subprocess as a worker, the parent process does nothing, so ignore it.
        },
        {
            regexp    => qr/pricer_load_runner\.pl/,
            dd_prefix => "$dd_prefix.pricer_load_runner",
            # Still don't know why pricer_load_runner will fork subprocess sometimes. let's filter it first
            ppid => 'is 1',
        },
        {
            # TODO when finish, this process will no there, so we must process it before kill
            regexp    => qr/proposal_sub.pl/,
            dd_prefix => "$dd_prefix.proposal_sub"
        },

    );
    state %data;
    state $current_market;
    if ($start_market) {
        $current_market = $start_market;
        %data           = ();
    }
    # sort to keep them same order
    my @processes = sort { $a->{pid} <=> $b->{pid} } $t->table->@*;
    foreach my $cfg_idx (0 .. $#process_cfg) {
        my $cfg = $process_cfg[$cfg_idx];
        # the idx of processes that have same name
        my $idx = 0;
        foreach my $p (@processes) {
            next unless $p->{cmndline} =~ $cfg->{regexp};
            next if ($cfg->{ppid} // '') eq 'not 1' && $p->{ppid} == 1;
            next if ($cfg->{ppid} // '') eq 'is 1'  && $p->{ppid} != 1;
            $idx++;
            foreach my $f (qw(size rss)) {
                stats_gauge("$cfg->{dd_prefix}.$f", $p->{$f}, {tags => ["tag:idx$idx", "tag:$current_market"]});
                if ($start_market) {
                    $data{$cfg_idx}{$f}{$idx}{start} = $p->{$f};
                } elsif (exists $data{$cfg_idx}{$f}{$idx}{start}) {
                    stats_gauge(
                        "$cfg->{dd_prefix}.${f}.delta",
                        $p->{$f} - $data{$cfg_idx}{$f}{$idx}{start},
                        {tags => ["tag:idx$idx", "tag:$current_market"]});
                } else {
                    warn "no start value of $cfg->{dd_prefix}.${f} when try to calculate the delta value";
                }
            }
        }
    }
}

sub dd_time {
    my ($start_market) = @_;
    state $last_time;
    state $current_market;
    if ($start_market) {
        $last_time      = time();
        $current_market = $start_market;
        return;
    }
    stats_gauge("qaloadtest.time.$current_market", time() - $last_time);
    return;
}

sub dd_memory_and_time {
    dd_memory(@_);
    dd_time(@_);
}
