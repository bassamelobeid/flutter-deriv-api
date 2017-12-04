#!/usr/bin/env perl

# DESCRIPTION
#
# We will start using this script for post release verification to ensure each time
# we do a production release, it does not break our pricing for japan.
#
# What does this script do?
# This script will reprice contracts for japan based on csv input, to ensure reprice works properly for japan.
# It also checks that , payout - ask = ask of the opposite contract.

use strict;
use warnings;

use feature qw(say);

use BOM::Platform::Runtime;

use BOM::Product::Contract::Finder::Japan;
use BOM::Product::ContractFactory qw(produce_contract produce_batch_contract);
use BOM::Product::Contract::Batch;
use BOM::Pricing::JapanContractDetails;
use BOM::MarketData qw(create_underlying);

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

local $ENV{PGSERVICEFILE} = '/home/nobody/.pg_service_backprice.conf';

my $threshold = 0.001;

while (<STDIN>) {
    # Get line of data from STDIN
    # Data is in csv in the form of
    # shortcode,currency,payout,ask_price,bid_price,extra_info
    chomp(my ($shortcode, $currency, $payout, $ask_price, $bid_price, $extra) = split /,/, $_);

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

    my $ask_percentage_diff = ($ask_price == 0) ? 0 : abs($recalculated_ask_price - $ask_price) / $ask_price;
    my $bid_percentage_diff = ($bid_price == 0) ? 0 : abs($recalculated_bid_price - $bid_price) / $bid_price;

    if ($ask_percentage_diff > $threshold or $bid_percentage_diff > $threshold) {
        print
            "Recalculated price not matching: shortcode: $shortcode Logged ask: $ask_price Logged bid: $bid_price Recalc ask : $recalculated_ask_price Recalc bid: $recalculated_bid_price \n";
    }
}

