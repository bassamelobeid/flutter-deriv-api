#!/usr/bin/env perl 
use strict;
use warnings;

use feature qw(say);

use Data::Dumper;

use BOM::Platform::Runtime;
use LandingCompany::Offerings qw(get_offerings_with_filter);

use BOM::Product::Contract::Finder::Japan;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData qw(create_underlying);
use JSON::XS qw(encode_json);
use List::UtilsBy qw(rev_nsort_by);
use Pricing::Engine::EuropeanDigitalSlope;
use Date::Utility;
use POSIX qw(floor);
use Time::HiRes qw(clock_nanosleep CLOCK_REALTIME TIMER_ABSTIME);

# How long each Redis key should persist for - we'll refresh the list
# when the key(s) expire
use constant JOB_QUEUE_TTL => 60;

use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr), log_level => 'info';

my $redis = BOM::System::RedisReplicated::redis_pricer;
while(1) {
    my $start = Time::HiRes::time;
    # Get a full list of symbols since some may have been updated/disabled
    # since the last time
    my @symbols = get_offerings_with_filter(
        BOM::Platform::Runtime->instance->get_offerings_config,
        'underlying_symbol', {
            landing_company => 'japan'
        }
    );
    my $now = Time::HiRes::time;
    $log->debugf("Retrieved symbols - %.2fms", 1000 * ($now - $start));

    my @jobs;
    my $skipped = 0;
    for my $symbol (@symbols) {
        my $symbol_start = Time::HiRes::time;
        my $contracts_for = BOM::Product::Contract::Finder::Japan::available_contracts_for_symbol({
            symbol => $symbol
        });
        $now = Time::HiRes::time;
        $log->debugf("Retrieved contracts for %s - %.2fms", $symbol, 1000 * ($now - $symbol_start));

        for my $contract_parameters (@{$contracts_for->{available}}) {
            # Expired entries 
            my %expired;
            $expired{ref($_) ? join(',', @$_) : $_} = 1 for @{$contract_parameters->{expired_barriers}};
            BARRIER:
            for my $barrier (@{$contract_parameters->{available_barriers}}) {
                my ($barrier_desc) = map {; ref($_) ? join(',', @$_) : $_ } $barrier;
                if(exists $expired{$barrier_desc}) {
                    $skipped++;
                } else {
                    my @pricing_queue_args = (
                        amount               => 1000,
                        basis                => 'payout',
                        currency             => 'JPY',
                        contract_type        => $contract_parameters->{contract_type},
                        price_daemon_cmd     => 'price',
                        skips_price_validation => 1,
                        landing_company      => 'japan',
                        date_expiry          => $contract_parameters->{trading_period}{date_expiry}{epoch},
                        trading_period_start => $contract_parameters->{trading_period}{date_start}{epoch},
                        symbol               => $symbol,
                        (
                         ref($barrier)
                         ? (
                             low_barrier  => $barrier->[0],
                             high_barrier => $barrier->[1],
                           )
                         : (
                             barrier => $barrier
                           )
                        )
                    );
                    $log->debugf("Contract parameters will be %s", \@pricing_queue_args);
                    # my $contract = produce_contract(@contract_parameters);
                    push @jobs, \@pricing_queue_args;
                }
            }
        }
    }
    DataDog::DogStatsd::Helper::stats_timing("pricer_queue.japan.jobs", 0 + @jobs);
    $log->debugf("Total of %d jobs to process, %d skipped", 0 + @jobs, $skipped);
    # We set TTL to slightly higher (one full pricing interval) than the refresh time, in case there's any
    # delay on starting the next cycle
    $redis->setex("PRICER_KEYS::" . encode_json($_), 1 + JOB_QUEUE_TTL, "1") for @jobs;

    # Using a timing metric here so we can get min/max/avg
    DataDog::DogStatsd::Helper::stats_timing("pricer_queue.japan.jobs.count", 0 + @jobs);
    DataDog::DogStatsd::Helper::stats_timing("pricer_queue.japan.jobs.gather_time", 1000 * ($now - $start));

    # Sleep to start of next minute
    {
        my $now = Time::HiRes::time;
        my $target = 60e9 * (1 + floor($now / 60));
        $log->debugf("Will sleep until %s (current time %s)", map $_->iso8601, Date::Utility->new($target / 1e9), Date::Utility->new);
        clock_nanosleep(CLOCK_REALTIME, $target, TIMER_ABSTIME);
    }
}

