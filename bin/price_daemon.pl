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
use LWP::Simple;

my $internal_ip = get("http://169.254.169.254/latest/meta-data/local-ipv4");
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
        DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.forks.count', (scalar @running_forks), {tags => ['tag:' . $internal_ip]});
        warn "Started a new fork [$pid]\n";
    });
$pm->run_on_finish(
    sub {
        my ($pid, $exit_code) = @_;
        @running_forks = grep { $_ != $pid } @running_forks;
        DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.forks.count', (scalar @running_forks), {tags => ['tag:' . $internal_ip]});
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
    my $pricing_count         = 0;
    my $current_pricing_epoch = time;
    while (my $key = $redis->brpop("pricer_jobs", 0)) {
        DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.idle.time', 1000 * Time::HiRes::tv_interval($tv), {tags => ['tag:' . $internal_ip]});
        $tv = [Time::HiRes::gettimeofday];

        my $next = $key->[1];
        $next =~ s/^PRICER_KEYS:://;
        my $payload = JSON::XS::decode_json($next);
        my $params  = {@{$payload}};
        my $trigger = $params->{symbol};

        my $current_time    = time;
        my $current_spot_ts = BOM::Market::Underlying->new($params->{symbol})->spot_tick->epoch;
        my $last_price_ts   = $redis->get($next) || 0;

        next if ($current_spot_ts == $last_price_ts and $current_time - $last_price_ts <= 10);

        $redis->set($next, $current_time);
        $redis->expire($next, 300);
        my $response = BOM::RPC::v3::Contract::send_ask({args => $params}, 1);

        DataDog::DogStatsd::Helper::stats_inc('pricer_daemon.price.call', {tags => ['tag:' . $internal_ip]});
        DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.price.time', $response->{rpc_time}, {tags => ['tag:' . $internal_ip]});

        warn "Pricing time too long: " . $response->{rpc_time} . ' ' . Data::Dumper::Dumper($params) if $response->{rpc_time}>1000;

        my $subsribers_count = $redis->publish($key->[1], encode_json($response));
        # if None was subscribed, so delete the job
        if ($subsribers_count == 0) {
            $redis->del($key->[1], $next);
        }
        DataDog::DogStatsd::Helper::stats_count('pricer_daemon.queue.subscribers', $subsribers_count, {tags => ['tag:' . $internal_ip]});
        DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.process.time', 1000 * Time::HiRes::tv_interval($tv), {tags => ['tag:' . $internal_ip]});
        my $end_time = Time::HiRes::time;
        DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.process.end_time', 1000 * ($end_time - int($end_time)), {tags => ['tag:' . $internal_ip]});
        $pricing_count++;
        if ($current_pricing_epoch != time) {
            DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.price.count_per_second', $pricing_count, {tags => ['tag:' . $internal_ip]});
            $pricing_count = 0;
            $current_pricing_epoch = time;
        }
        $tv = [Time::HiRes::gettimeofday];
    }
    $pm->finish;
}
