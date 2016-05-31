#!/usr/bin/env perl
use strict;
use warnings;
use Mojo::Redis::Processor;
use Parallel::ForkManager;
use JSON;
use BOM::System::RedisReplicated;
use BOM::RPC::PricerDaemon;
use Getopt::Long;
use DataDog::DogStatsd::Helper;
use sigtrap qw/handler signal_handler normal-signals/;

my $workers = 4;
GetOptions ("workers=i" => \$workers,) ;

my $pm = new Parallel::ForkManager($workers);

my @running_forks;

$pm->run_on_start(
    sub {
        my $pid = shift;
        push @running_forks, $pid;
    }
);

$pm->run_on_finish(
    sub {
        my ($pid, $exit_code) = @_;

        @running_forks = grep {$_ != $pid } @running_forks;
    }
);

sub signal_handler {
    foreach my $pid (@running_forks) {
        `kill -9 $pid`, "\n";
    }

    exit 0;
}


sub _redis_read {
    my $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-replicated.yml');
    return RedisDB->new(
        host    => $config->{read}->{host},
        port    => $config->{read}->{port},
        ($config->{read}->{password} ? ('password', $config->{read}->{password}) : ()));
}

sub _redis_pricer {
        my $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml');
        return RedisDB->new(
            host    => $config->{write}->{host},
            port    => $config->{write}->{port},
            ($config->{write}->{password} ? ('password', $config->{write}->{password}) : ()));
}

while (1) {
    my $pid = $pm->start and next;
    DataDog::DogStatsd::Helper::stats_count('pricer_daemon.forks.count', 1);
    DataDog::DogStatsd::Helper::stats_count('pricer_daemon.forks.idle.count', 1);
    my $rp = Mojo::Redis::Processor->new(
        'read_conn'   => _redis_pricer,
        'write_conn'  => _redis_pricer,
        'daemon_conn' => _redis_read,
        'usleep'      => 100000,
        'retry'       => 100,
    );

    my $next = $rp->next;
    if ($next) {
        DataDog::DogStatsd::Helper::stats_count('pricer_daemon.forks.idle.count', -1);
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
        sleep (30);
        DataDog::DogStatsd::Helper::stats_count('pricer_daemon.forks.idle.count', -1);
    }
    print "Ending the child\n";
    DataDog::DogStatsd::Helper::stats_count('pricer_daemon.forks.count', -1);
    $pm->finish;
}
