#!/etc/rmg/bin/perl
use strict;
use warnings;

use sigtrap handler => 'signal_handler', 'normal-signals';

use LWP::Simple;
use Getopt::Long;

use Parallel::ForkManager;

use BOM::RPC::PriceDaemon;
use Sys::Info;
use List::Util qw(max);

my $internal_ip     = get("http://169.254.169.254/latest/meta-data/local-ipv4");
my $workers         = 4;
my %required_params = (
    price => [qw(contract_type currency symbol)],
    bid   => [qw(contract_id short_code currency landing_company)],
);

GetOptions(
    "workers=i" => \my $workers,
    "queues=s"  => \my $queues,
);
$queues ||= 'pricer_jobs';
$workers ||= max(1, Sys::Info->new->device("CPU")->count);

# tune cache: up to 2s
$ENV{QUANT_FRAMEWORK_HOLIDAY_CACHE} = $ENV{QUANT_FRAMEWORK_PATRIALTRADING_CACHE} = 2;    ## nocritic
my $pm = Parallel::ForkManager->new($workers);

my @running_forks;
sub signal_handler {
    kill KILL => @running_forks;
    exit 0;
}

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

while (1) {
    $pm->start and next;
    my $daemon = BOM::RPC::PriceDaemon->new(
        tags => [ 'tag:' . $internal_ip ]
    );
    $daemon->run(queues => [ split /,/, $queues ]);
    $pm->finish;
}

