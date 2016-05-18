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

while (1) {
    my $pid = $pm->start and next;

    my $rp = Mojo::Redis::Processor->new(
        'read_conn'   => BOM::System::RedisReplicated::redis_pricer,
        'write_conn'  => BOM::System::RedisReplicated::redis_pricer,
        'daemon_conn' => BOM::System::RedisReplicated::redis_read,
    );

    my $next = $rp->next;
    if ($next) {
        print "next [$next]\n";
        my $p = BOM::RPC::PricerDaemon->new(data=>$rp->{data}, key=>$rp->_processed_channel);
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
