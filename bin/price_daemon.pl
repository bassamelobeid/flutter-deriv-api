#!/etc/rmg/bin/perl
use strict;
use warnings;
use Parallel::ForkManager;
use JSON::XS;
use BOM::System::RedisReplicated;
use Getopt::Long;
use DataDog::DogStatsd::Helper;
use BOM::RPC::v3::Contract;
use sigtrap handler => 'signal_handler', 'normal-signals';
use BOM::MarketData qw(create_underlying);
use BOM::Product::ContractFactory::Parser qw(shortcode_to_parameters);
use Data::Dumper;
use LWP::Simple;
use BOM::Platform::Runtime;
use BOM::RPC::PriceDaemon;
use DBIx::TransactionManager::Distributed qw(txn);
use List::Util qw(first);
use Time::HiRes ();

my $internal_ip     = get("http://169.254.169.254/latest/meta-data/local-ipv4");
my $workers         = 4;
my %required_params = (
    price => [qw(contract_type currency symbol)],
    bid   => [qw(contract_id short_code currency landing_company)],
);

GetOptions(
    "workers=i" => \$workers,
    "queues=s"  => \my $queues,
);
$queues ||= 'pricer_jobs';

# tune cache: up to 2s
$ENV{QUANT_FRAMEWORK_HOLIDAY_CACHE} = $ENV{QUANT_FRAMEWORK_PATRIALTRADING_CACHE} = 2;    ## nocritic
my $pm = Parallel::ForkManager->new($workers);

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
    my $daemon = BOM::RPC::PriceDaemon->new;
    $daemon->run(queues => [ split /,/, $queues ]);
    $pm->finish;
}

