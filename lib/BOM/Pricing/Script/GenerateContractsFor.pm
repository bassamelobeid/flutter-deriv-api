package BOM::Pricing::Script::GenerateContractsFor;
use strict;
use warnings;

use BOM::Platform::RedisReplicated;
use BOM::Pricing::ContractsForGenerator;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);
use JSON::MaybeXS;
use LandingCompany::Offerings qw(get_offerings_with_filter);
use LandingCompany::Registry;
use Time::HiRes qw(time);
use Volatility::Seasonality;

sub run {
    my $products = {map { $_ => 1 } qw/basic multi_barrier/};
    die "$0 <product>" unless defined $products->{$ARGV[0]};
    do_loop($ARGV[0]);
}

sub do_loop {
    my $product = shift;
    Volatility::Seasonality::warmup_cache();
    my $redis = BOM::Platform::RedisReplicated::redis_pricer;
    my $json  = JSON::MaybeXS->new;
    while (1) {
        my $start                    = time;
        my $ul_per_landing_companies = {};
        for my $lc (LandingCompany::Registry::all()) {
            my @ul = get_offerings_with_filter(BOM::Platform::Runtime->instance->get_offerings_config,
                'underlying_symbol', {landing_company => $lc->short});
            for (@ul) {
                push @{$ul_per_landing_companies->{$_}}, $lc->short;
            }
        }

        for my $ul (keys %$ul_per_landing_companies) {
            for my $lc (@{$ul_per_landing_companies->{$ul}}) {
                my $contracts = BOM::Pricing::ContractsForGenerator::contracts_for({
                    symbol            => $ul,
                    product_type      => $product,
                    landing_company   => $lc,
                    iteration_started => int($start),
                });
                $redis->set(join(':', 'contracts_for', $lc, $product, $ul), $json->encode($contracts), EX => 30);
            }
        }
        stats_timing('pricing.contracts_for.timing', time - $start, {tags => ["product:$product"]});
    }
    return;
}

1;
