package BOM::Pricing::ContractsForGenerator;

use strict;
use warnings;

use LandingCompany::Offerings qw(get_offerings_with_filter);
use Time::HiRes qw/time/;
use LandingCompany::Registry;
use Data::Dumper;
use Volatility::Seasonality;
use BOM::Product::Contract::Finder::Japan;
use BOM::Product::Contract::Finder;
use BOM::Platform::RedisReplicated;
use JSON::MaybeXS;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);

sub run {
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
                my $contracts = contracts_for({
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

sub contracts_for {
    my $args = shift;

    my $product_type = delete $args->{product_type};
    my $contracts_for;

    if ($product_type eq 'multi_barrier') {
        $contracts_for = BOM::Product::Contract::Finder::Japan::available_contracts_for_symbol($args);
    } else {
        $contracts_for = BOM::Product::Contract::Finder::available_contracts_for_symbol($args);
        # this is temporary solution till the time front apps are fixed
        # filter CALLE|PUTE only for non japan
        $contracts_for->{available} = [grep { $_->{contract_type} !~ /^(?:CALLE|PUTE)$/ } @{$contracts_for->{available}}]
            if ($contracts_for and $contracts_for->{hit_count} > 0);
    }

    return {
        _generated => time,
        value      => $contracts_for
    };
}

1;
