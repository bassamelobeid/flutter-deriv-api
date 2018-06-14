package BOM::Config::ContractPricingLimits;

use strict;
use warnings;
use BOM::Config;
use Exporter qw(import);
our @EXPORT_OK = qw(market_pricing_limits);

sub market_pricing_limits {
    my ($currencies, $lc, $markets) = @_;

    $lc ||= "default_landing_company";
    $markets ||= ["default_market"];

    my $bet_limits = BOM::Config::quants()->{bet_limits};
    my $lc_min     = $bet_limits->{min_stake}->{$lc} || $bet_limits->{min_stake}->{default_landing_company};
    my $lc_max     = $bet_limits->{max_payout}->{$lc} || $bet_limits->{max_payout}->{default_landing_company};

    my $limits = {};

    for my $market (@$markets) {

        my $market_min = $lc_min->{$market} || $lc_min->{default_market};
        my $market_max = $lc_max->{$market} || $lc_max->{default_market};

        for my $currency (@$currencies) {

            my $min_stake  = $market_min->{$currency};
            my $max_payout = $market_max->{$currency};

            $limits->{$market}->{$currency}->{max_payout} = $max_payout;
            $limits->{$market}->{$currency}->{min_stake}  = $min_stake;
        }
    }

    return $limits;
}

1;
