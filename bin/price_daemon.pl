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
use Data::Dumper;

my $workers = 4;
GetOptions(
    "workers=i" => \$workers,
);

my $pm = new Parallel::ForkManager($workers);

my @running_forks;

$pm->run_on_start(
    sub {
        my $pid = shift;
        push @running_forks, $pid;
        DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.forks.count', (scalar @running_forks));
        warn "Started a new fork [$pid]\n";
    });
$pm->run_on_finish(
    sub {
        my ($pid, $exit_code) = @_;
        @running_forks = grep { $_ != $pid } @running_forks;
        DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.forks.count', (scalar @running_forks));
        warn "Fork [$pid] ended with exit code [$exit_code]\n";
    });

sub signal_handler {
    kill KILL => @running_forks;
    exit 0;
}

while (1) {
    $pm->start and next;

    my $redis = BOM::System::RedisReplicated::redis_pricer;

    my $tv                    = [Time::HiRes::gettimeofday];
    my $stat_count            = {};
    my $current_pricing_epoch = time;
    while (my $key = $redis->brpop("pricer_jobs", 0)) {
        DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.idle.time', 1000 * Time::HiRes::tv_interval($tv));
        $tv = [Time::HiRes::gettimeofday];

        my $next = $key->[1];
        $next =~ s/^PRICER_KEYS:://;
        my $payload = JSON::XS::decode_json($next);
        my $params  = {@{$payload}};

        my $price_daemon_cmd = delete $params->{price_daemon_cmd};
        my $current_time     = time;
        my $response;

        if ($price_daemon_cmd eq 'price') {

            my $current_spot_ts = BOM::Market::Underlying->new($params->{symbol})->spot_tick->epoch;
            my $last_price_ts   = $redis->get($next) || 0;

            next if ($current_spot_ts == $last_price_ts and $current_time - $last_price_ts <= 10);

            $redis->set($next, $current_time);
            $redis->expire($next, 300);
            $response = BOM::RPC::v3::Contract::send_ask({args => $params}, 1);

        } elsif ($price_daemon_cmd eq 'bid') {

            $response = BOM::RPC::v3::Contract::send_bid({args => $params});

        }

        if ($price_daemon_cmd) {
            DataDog::DogStatsd::Helper::stats_inc("pricer_daemon.$price_daemon_cmd.call");
            DataDog::DogStatsd::Helper::stats_timing("pricer_daemon.$price_daemon_cmd.time", $response->{rpc_time});
            $response->{price_daemon_cmd} = $price_daemon_cmd;
        }

        warn "Pricing time too long: " . $response->{rpc_time} . ' ' . Data::Dumper::Dumper($params) if $response->{rpc_time}>1000;

        my $subsribers_count = $redis->publish($key->[1], encode_json($response));
        # if None was subscribed, so delete the job
        if ($subsribers_count == 0) {
            $redis->del($key->[1], $next);
        }
        DataDog::DogStatsd::Helper::stats_count('pricer_daemon.queue.subscribers', $subsribers_count);
        DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.process.time', 1000 * Time::HiRes::tv_interval($tv));
        my $end_time = Time::HiRes::time;
        DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.process.end_time', 1000 * ($end_time - int($end_time)));
        $stat_count->{$price_daemon_cmd}++;
        if ($current_pricing_epoch != time) {
            for my $key (%$stat_count) {
                DataDog::DogStatsd::Helper::stats_gauge("pricer_daemon.$key.count_per_second", $stat_count->{$key});
            }
            $stat_count = {};
            $current_pricing_epoch = time;
        }
        $tv = [Time::HiRes::gettimeofday];
    }
    $pm->finish;
}
