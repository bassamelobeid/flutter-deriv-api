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

use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr);

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
    $log->infof("Retrieved symbols - %.2fms", 1000 * ($now - $start));

    my @jobs;
    for my $symbol (@symbols) {
        my $contracts_for = BOM::Product::Contract::Finder::Japan::available_contracts_for_symbol({
            symbol => $symbol
        });
        $now = Time::HiRes::time;
        $log->infof("Retrieved contracts for %s - %.2fms", $symbol, 1000 * ($now - $start));
        $start = $now;

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
                    my %pricing_queue_args = (
                        basis                => 'payout',
                        currency             => 'JPY',
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
                    my @contract_parameters = (
                        bet_type             => $contract_parameters->{contract_type},
                        fixed_expiry         => 1,
                        payout               => 1000,
                        %pricing_queue_args,
                    );
                    $pricing_queue_args{proposal} = 1;
                    $pricing_queue_args{contract_type} = $contract_parameters->{contract_type};
                    my $contract = produce_contract(@contract_parameters);
                    push @jobs, 'PRICER_KEYS::' . encode_json([
                        short_code => $contract->shortcode,
                        amount => 1000,
                        map {; $_ => $pricing_queue_args{$_} } sort keys %pricing_queue_args
                    ]);
                }
            }
        }
    }
    $log->infof("Total of %d jobs to process, %d skipped", 0 + @jobs, $skipped);
    my $redis = BOM::System::RedisReplicated::redis_pricer;
    $redis->set("PRICER_KEYS::$_", EX => 60) for @jobs;
    # Sleep to start of next minute
    clock_nanosleep(CLOCK_REALTIME, 60e9 * (1 + floor(time / 60)), TIMER_ABSTIME);
}

