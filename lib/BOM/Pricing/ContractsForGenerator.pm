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
        my $start = time;
        $ENV{ITERATION_STARTED} = int($start);    ## no critic (RequireLocalizedPunctuationVars)
        my @underlyings = get_offerings_with_filter(BOM::Platform::Runtime->instance->get_offerings_config, 'underlying_symbol');
        my $l;
        for my $lc (LandingCompany::Registry::all()) {
            $l->{$lc->short}->{ul} = {
                map { $_ => 1 } get_offerings_with_filter(
                    BOM::Platform::Runtime->instance->get_offerings_config,
                    'underlying_symbol', {landing_company => $lc->short})};

        }
        for my $ul (@underlyings) {
            for my $lc (keys %$l) {
                next unless $l->{$lc}->{ul}->{$ul};
                my $contracts = contracts_for({
                    contracts_for   => $ul,
                    product_type    => $product,
                    landing_company => $lc,
                });
                $redis->set(join(':', $lc, $product, $ul), $json->encode($contracts));
            }
        }
        stats_timing('pricing.contracts_for.timing', time - $start, {tags => ["product:$product"]});
        warn time - $start;
    }
    return;
}

sub contracts_for {
    my $args = shift;

    my $product_type = $args->{product_type};

    my $contracts_for;
    my $query_args = {
        symbol          => $args->{contracts_for},
        landing_company => $args->{landing_company},
    };

    if ($product_type eq 'multi_barrier') {
        $contracts_for = BOM::Product::Contract::Finder::Japan::available_contracts_for_symbol($query_args);
    } else {
        $contracts_for = BOM::Product::Contract::Finder::available_contracts_for_symbol($query_args);
        # this is temporary solution till the time front apps are fixed
        # filter CALLE|PUTE only for non japan
        $contracts_for->{available} = [grep { $_->{contract_type} !~ /^(?:CALLE|PUTE)$/ } @{$contracts_for->{available}}]
            if ($contracts_for and $contracts_for->{hit_count} > 0);
    }

    return $contracts_for;
}

1;
