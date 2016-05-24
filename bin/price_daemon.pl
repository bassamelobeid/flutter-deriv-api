#!/usr/bin/env perl
use strict;
use warnings;
use Mojo::Redis::Processor;
use Parallel::ForkManager;
use JSON;
use BOM::System::RedisReplicated;
use BOM::RPC::PricerDaemon;
use Getopt::Long;

my $workers = 4;
GetOptions ("workers=i" => \$workers,) ;

my $pm = new Parallel::ForkManager($workers);

sub _redis_read {
    my $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-replicated.yml');
    return RedisDB->new(
        timeout => 10,
        host    => $config->{read}->{host},
        port    => $config->{read}->{port},
        ($config->{read}->{password} ? ('password', $config->{read}->{password}) : ()));
}

sub _redis_pricer {
        my $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml');
        return RedisDB->new(
            timeout => 10,
            host    => $config->{write}->{host},
            port    => $config->{write}->{port},
            ($config->{write}->{password} ? ('password', $config->{write}->{password}) : ()));
}

while (1) {
    my $pid = $pm->start and next;

    my $rp = Mojo::Redis::Processor->new(
        'read_conn'   => _redis_pricer,
        'write_conn'  => _redis_pricer,
        'daemon_conn' => _redis_read,
    );

    my $next = $rp->next;
    if ($next) {
        print "next [$next]\n";
        my $p = BOM::RPC::PricerDaemon->new(data=>$rp->{data}, key=>$rp->_processed_channel);

        # Trigger channel (like FEED::R_25) comes as part of data workload. Here we define what will happend whenever there is a new signal in that channel.
        $rp->on_trigger(
            sub {
                my $payload = shift;
                my $result = $p->price;
                print "res [$result]\n";
                return $p->price;
            });
    } else {
        print "no job found\n";
        sleep 3;
    }
    print "Ending the child\n";
    $pm->finish;
}
