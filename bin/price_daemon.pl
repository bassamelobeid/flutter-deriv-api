#!/usr/bin/env perl
use strict;
use warnings;
use Parallel::ForkManager;
use JSON;
use BOM::System::RedisReplicated;
use Getopt::Long;
use DataDog::DogStatsd::Helper;
use BOM::RPC::v3::Contract;
use sigtrap qw/handler signal_handler normal-signals/;

my $workers = 4;
GetOptions ("workers=i" => \$workers,) ;

my $pm = new Parallel::ForkManager($workers);

my @running_forks;

$pm->run_on_start(
    sub {
        my $pid = shift;
        push @running_forks, $pid;
        DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.forks.count', (scalar @running_forks));
        warn "Started a new fork [$pid]\n";
    }
);
$pm->run_on_finish(
    sub {
        my ($pid, $exit_code) = @_;
        @running_forks = grep {$_ != $pid } @running_forks;
        DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.forks.count', (scalar @running_forks));
        warn "Fork [$pid] ended with exit code [$exit_code]\n";
    }
);
sub signal_handler {
    kill KILL=>@running_forks;
    exit 0;
}

while (1) {
    $pm->start and next;

    my $redis = BOM::System::RedisReplicated::redis_pricer;

    my $tv = [Time::HiRes::gettimeofday];
    while (my $key = $redis->brpop("pricer_jobs", 0)) {
        DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.idle.time', 1000 * Time::HiRes::tv_interval($tv));

        my $next = $key->[1];
        $next =~ s/^PRICER_KEYS:://;
        my $payload  = JSON::XS::decode_json($next);
        my $params   = {@{$payload}};
        my $trigger  = $params->{symbol};

        my $current_time = time;
        my $current_spot_ts = BOM::Market::Underlying->new($params->{symbol})->spot_tick->epoch;
        my $last_price_ts = $redis->get($next) || 0;

        next if ($current_spot_ts==$last_price_ts and $current_time - $last_price_ts<=10 );

        $redis->set($next, $current_time);
        my $response = BOM::RPC::v3::Contract::send_ask({args => $params}, 1);

        DataDog::DogStatsd::Helper::stats_inc('pricer_daemon.price.call');
        DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.price.time', $response->{rpc_time});

        my $subsribers_count = $redis->publish($key->[1], encode_json($response));
        # if None was subscribed, so delete the job
        if ($subsribers_count == 0) {
            $redis->del($key->[1], $next);
        }
        DataDog::DogStatsd::Helper::stats_count('pricer_daemon.queue.subscribers', $subsribers_count);
        $tv = [Time::HiRes::gettimeofday];
    }
    $pm->finish;
}
