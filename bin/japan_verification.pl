#!/usr/bin/env perl

# DESCRIPTION
#
# We will start using this script for post release verification to ensure each time
# we do a production release, it does not break our pricing for japan.
#
# What does this script do?
# This script will price contracts, save the pricing parameters in memory , and 
# it will reprice, to ensure reprice works properly for japan.
# It also checks that , payout - ask = ask of the opposite contract.
# Measures pricing speed.

use strict;
use warnings;

use feature qw(say);

use BOM::Platform::Runtime;
use LandingCompany::Offerings qw(get_offerings_with_filter);

use BOM::Product::Contract::Finder::Japan;
use BOM::Product::ContractFactory qw(produce_contract produce_batch_contract);
use BOM::Product::Contract::Batch;
use BOM::Pricing::JapanContractDetails;
use BOM::MarketData qw(create_underlying);

use JSON::XS qw(encode_json);
use List::UtilsBy qw(rev_nsort_by);
use Pricing::Engine::EuropeanDigitalSlope;
use Date::Utility;
use POSIX qw(floor);
use Time::HiRes qw(clock_nanosleep CLOCK_REALTIME TIMER_ABSTIME);

use List::Util qw(min max sum);
use Scalar::Util qw(looks_like_number);

# How long each Redis key should persist for - we'll refresh the list
# when the key(s) expire
use constant JOB_QUEUE_TTL => 60;

# Number of keys to set per Redis call, used to reduce network latency overhead
use constant JOBS_PER_BATCH => 30;
# Reload appconfig regularly, in case any underlyings have been disabled
use constant APP_CONFIG_REFRESH_INTERVAL => 60;

use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr), log_level => 'info';

my %opposite_contract = (
    'EXPIRYRANGEE' => 'EXPIRYMISS',
    'CALLE'        => 'PUT',
    'ONETOUCH'     => 'NOTOUCH',
    'RANGE'        => 'UPORDOWN',
    'EXPIRYMISS'   => 'EXPIRYRANGEE',
    'PUT'          => 'CALLE',
    'NOTOUCH'      => 'ONETOUCH',
    'UPORDOWN'     => 'RANGE',
);

my @contracts_to_reprice;
my @time_records;

my $payout = 1000;

my $appconfig_age = 0;
while (1) {
    my $start = Time::HiRes::time;

    if ($start - $appconfig_age >= APP_CONFIG_REFRESH_INTERVAL) {
        BOM::Platform::Runtime->instance->app_config->check_for_update;
        $appconfig_age = $start;
    }
    # Get a full list of symbols since some may have been updated/disabled
    # since the last time
    my @symbols =
        get_offerings_with_filter(BOM::Platform::Runtime->instance->get_offerings_config, 'underlying_symbol', {landing_company => 'japan'});
    my $now = Time::HiRes::time;
    $log->debugf("Retrieved symbols - %.2fms", 1000 * ($now - $start));

    my @jobs;
    my $skipped = 0;
    for my $symbol (@symbols) {
        my $symbol_start = Time::HiRes::time;
        my $contracts_for = BOM::Product::Contract::Finder::Japan::available_contracts_for_symbol({symbol => $symbol});
        $now = Time::HiRes::time;
        $log->debugf("Retrieved contracts for %s - %.2fms", $symbol, 1000 * ($now - $symbol_start));

        for my $contract_parameters (@{$contracts_for->{available}}) {
            # Expired entries
            my %expired;
            $expired{ref($_) ? join(',', @$_) : $_} = 1 for @{$contract_parameters->{expired_barriers}};
            BARRIER:
            for my $barrier (@{$contract_parameters->{available_barriers}}) {
                my ($barrier_desc) = map { ; ref($_) ? join(',', @$_) : $_ } $barrier;
                if (exists $expired{$barrier_desc}) {
                    $skipped++;
                    next;
                }

                $log->debugf("type: %s", $contract_parameters->{contract_type});
                my %pricing_queue_args = (
                    payout                 => $payout,
                    currency               => 'JPY',
                    bet_types              => [$contract_parameters->{contract_type}, $opposite_contract{$contract_parameters->{contract_type}}],
                    underlying             => create_underlying($symbol),
                    skips_price_validation => 1,
                    landing_company        => 'japan',
                    date_expiry            => $contract_parameters->{trading_period}{date_expiry}{epoch},
                    trading_period_start   => $contract_parameters->{trading_period}{date_start}{epoch},
                    symbol                 => $symbol,
                    (
                        ref($barrier)
                        ? (
                            high_barrier => $barrier->[1],
                            low_barrier  => $barrier->[0])
                        : (barrier => $barrier)
                    ),
                );

                my $batch_start = Time::HiRes::time;

                my $batch_contract = produce_batch_contract(\%pricing_queue_args);

                my $contracts = $batch_contract->_contracts;

                if (($contracts->[0]->ask_price + $contracts->[1]->bid_price) != $payout) {
                    print "###Mismatched contract:"
                        . $contracts->[0]->shortcode
                        . " ask: "
                        . $contracts->[0]->ask_price
                        . " bid: "
                        . $contracts->[1]->bid_price . "\n";
                }

                my $batch_end = Time::HiRes::time;
                my $elapsed   = $batch_end - $batch_start;
                push @time_records, $elapsed;

                push @contracts_to_reprice,
                      $contracts->[0]->shortcode . ","
                    . $contracts->[0]->ask_price . ","
                    . $contracts->[0]->bid_price . ","
                    . $contracts->[0]->extra_info('string');
                push @contracts_to_reprice,
                      $contracts->[1]->shortcode . ","
                    . $contracts->[1]->ask_price . ","
                    . $contracts->[1]->bid_price . ","
                    . $contracts->[1]->extra_info('string');

                # Logging checks go here.
                my %contracts_to_log;
                my $trading_window_start = $contract_parameters->{trading_period}{date_start}{epoch} // '';

                CONTRACT:
                for my $contract (@{$batch_contract->_contracts}) {
                    next CONTRACT unless $contract->can('japan_pricing_info');

                    my $barrier_key =
                        $contract->two_barriers
                        ? ($contract->high_barrier->as_absolute) . '-' . ($contract->low_barrier->as_absolute)
                        : ($contract->barrier->as_absolute);

                    push @{$contracts_to_log{$barrier_key}}, $contract;
                }

                for my $contracts (values %contracts_to_log) {
                    if (@$contracts == 2) {
                        # For each contract, we pass the opposite contract to the logging function
                        warn "Issue in logging " . $contracts->[0]->shortcode
                            if (not defined $contracts->[0]->japan_pricing_info($trading_window_start, $contracts->[1]));
                        warn "Issue in logging " . $contracts->[1]->shortcode
                            if (not defined $contracts->[1]->japan_pricing_info($trading_window_start, $contracts->[0]));
                    } else {
                        warn "Had unexpected number of contracts for ->japan_pricing_info calls - types are " . join ',',
                            map { $_->contract_type } @$contracts;
                    }
                }
            }
        }
    }
    $log->debugf("Total of %d jobs to process, %d skipped", 0 + @jobs, $skipped);
    last;
}

# Now let's reprice

for my $contract_shortcode (@contracts_to_reprice) {
    my @params = split ',', $contract_shortcode;

    my $shortcode = $params[0];
    my $ask_price = $params[1];
    my $bid_price = $params[2];
    my $extra     = $params[3];

    my $pricing_parameters = BOM::Pricing::JapanContractDetails::verify_with_shortcode({
        shortcode       => $shortcode,
        currency        => 'JPY',
        landing_company => 'japan',
        ask_price       => $ask_price,
        bid_price       => $bid_price,
        action_type     => 'buy',
        extra           => $extra,
    });

    # Verify that parameters->{ask_probability} * payout = logged ask price
    # and parameters->{bid_probability} * payout = logged bid price

    my $ask_prob;
    my $bid_prob;
    foreach my $key (keys %{$pricing_parameters->{ask_probability}}) {
        $ask_prob += $pricing_parameters->{ask_probability}->{$key};

        my $bid_key = 'opposite_contract_' . $key;
        $bid_prob += $pricing_parameters->{opposite_contract}->{$bid_key};
    }

    $bid_prob = 1 - $bid_prob;

    my $recalculated_ask_price = $ask_prob * $payout;
    my $recalculated_bid_price = $bid_prob * $payout;

    if ($recalculated_ask_price != $ask_price or $recalculated_bid_price != $bid_price) {
        print
            "Recalculated price not matching: Logged ask: $ask_price Logged bid: $bid_price Recalc ask : $recalculated_ask_price Recalc bid: $recalculated_bid_price \n";
    }
}

# Print speed statistics

my $time_max = max(grep { looks_like_number($_) } @time_records);
my $time_min = min(grep { looks_like_number($_) } @time_records);
my $average  = sum(@time_records) / scalar(@time_records);

print "Pricing speed Min: $time_min Max: $time_max Avg: $average\n";

