use strict;
use warnings;
use Mojo::Redis::Processor;
use Parallel::ForkManager;
use JSON;
use BOM::System::RedisReplicated;
use BOM::RPC::PricerDaemon;

use constant MAX_WORKERS => 2;

my $pm = new Parallel::ForkManager(MAX_WORKERS);

sub _dameon_redis {
    my $action = shift;
    my $config = BOM::System::RedisReplicated::_config;
    return RedisDB->new(
        host => $config->{write}->{host},
        port => $config->{write}->{port},
        ($config->{write}->{password} ? ('password', $config->{write}->{password}) : ()),
    );
}

while (1) {
    my $pid = $pm->start and next;

    my $rp = Mojo::Redis::Processor->new(
        'read_conn'   => BOM::System::RedisReplicated::redis_read,
        'write_conn'  => BOM::System::RedisReplicated::redis_write,
        'daemon_conn' => _dameon_redis,
    );

    my $next = $rp->next;
    if ($next) {
        print "next [$next]\n";
        my $p = BOM::RPC::PricerDaemon->new(data=>$rp->{data});
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
