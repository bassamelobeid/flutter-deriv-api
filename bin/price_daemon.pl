#!/etc/rmg/bin/perl
use strict;
use warnings;

# load this file to force MOJO::JSON to use JSON::MaybeXS
use Mojo::JSON::MaybeXS;
use DataDog::DogStatsd::Helper;
use Date::Utility;
use Getopt::Long;
use LWP::UserAgent;
use List::Util qw(max);
use Parallel::ForkManager;
use Sys::Info;
use Path::Tiny qw(path);
use Volatility::LinearCache;
use Log::Any::Adapter qw(DERIV),
    stderr    => 'json',
    log_level => $ENV{BOM_LOG_LEVEL} // 'info';
use Log::Any qw($log);
use BOM::Pricing::PriceDaemon;

my $ua = LWP::UserAgent->new(timeout => 2);
$ua->env_proxy;
my $response = $ua->get("http://169.254.169.254/latest/meta-data/local-ipv4");

# Since this is only available in AWS, default to localhost for other environments
my $internal_ip = $response->is_success ? $response->content : '127.0.0.1';

GetOptions(
    "workers=i"              => \my $workers,
    "queues=s"               => \my $queues,
    "no-warmup=i"            => \my $nowarmup,
    'record_price_metrics:i' => \my $record_price_metrics,
    'pid-file=s'             => \my $pid_file,
);
$queues               ||= 'pricer_jobs';
$workers              ||= max(1, Sys::Info->new->device("CPU")->count);
$record_price_metrics ||= 0;

path($pid_file)->spew($$) if $pid_file;

my @running_forks;
my @workers = (0) x $workers;
my $index;

$SIG{TERM} = sub {
    # Give everything a chance to shut down gracefully
    kill TERM => @running_forks;
    sleep 2;
    # ... but don't wait all day.
    kill KILL => @running_forks;
    exit 1;
};

# tune cache: up to 2s
$ENV{QUANT_FRAMEWORK_HOLIDAY_CACHE} = $ENV{QUANT_FRAMEWORK_PATRIALTRADING_CACHE} = 2;    ## nocritic
my $pm = Parallel::ForkManager->new($workers);
$log->info("price_daemon service is running");
$pm->run_on_start(
    sub {
        my $pid = shift;
        ($index) = grep { $workers[$_] == 0 } 0 .. $#workers;
        $workers[$index] = $pid;
        push @running_forks, $pid;
    });
$pm->run_on_finish(
    sub {
        my ($pid, $exit_code) = @_;
        for (@workers) {
            if ($_ == $pid) {
                $_ = 0;
                last;
            }
        }
        @running_forks = grep { $_ != $pid } @running_forks;
    });

# warming up cache to eliminate pricing time spike on first price of underlying
# don't do this if no-warmup if provided
_warmup() unless $nowarmup;
# cache for updated seasonality in Redis not more often then 10 seconds
$Volatility::LinearCache::PERIOD_OF_CHECKING_FOR_UPDATES = 10;

while (1) {
    $pm->start and next;
    my $pid = $$;
    ($index) = grep { $workers[$_] == 0 } 0 .. $#workers;
    my $daemon = BOM::Pricing::PriceDaemon->new(
        tags                 => ['tag:' . $internal_ip],
        record_price_metrics => $record_price_metrics,
    );
    # Allow graceful shutdown
    $SIG{TERM} = sub {
        $daemon->stop;
    };
    $daemon->run(
        queues     => [split /,/, $queues],
        ip         => $internal_ip,
        pid        => $pid,
        fork_index => $index
    );
    $pm->finish;
}

# best way to warmup is to use some real contracts
sub _warmup {
    use Volatility::Seasonality;
    use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
    use BOM::MarketData               qw( create_underlying_db);

    my $start = time;
    Volatility::Seasonality::warmup_cache();

    my @forex = create_underlying_db->get_symbols_for(
        market            => ['forex'],
        submarket         => ['major_pairs', 'minor_pairs'],
        contract_category => 'ANY',
    );
    foreach (@forex) {
        my $test_contract = produce_contract('PUT_' . $_ . '_100_' . (time) . '_' . (time + 86400 * 6) . 'F_S10P_0', 'USD');
        $test_contract->pricing_vol;
    }
    DataDog::DogStatsd::Helper::stats_gauge("pricer_daemon.warmup_time", time - $start);
}
