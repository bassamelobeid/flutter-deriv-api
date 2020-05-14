package BOM::Config::Quants;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(market_pricing_limits minimum_payout_limit maximum_payout_limit minimum_stake_limit maximum_stake_limit);

use BOM::Config;

sub market_pricing_limits {
    my ($currencies, $lc, $markets, $contract_categories) = @_;

    $lc                  ||= "default_landing_company";
    $markets             ||= ["default_market"];
    $contract_categories ||= ['default_contract_category'];

    my $config = BOM::Config::quants()->{bet_limits};
    my $lc_min = $config->{min_stake}->{$lc} || $config->{min_stake}->{default_landing_company};
    my $lc_max = $config->{max_payout}->{$lc} || $config->{max_payout}->{default_landing_company};

    my $limits = {};

    for my $market (@$markets) {
        my $market_min = $lc_min->{$market} || $lc_min->{default_market};
        my $market_max = $lc_max->{$market} || $lc_max->{default_market};
        foreach my $contract_category (@$contract_categories) {
            my $cat_min = $market_min->{$contract_category} // $market_min->{default_contract_category};
            my $cat_max = $market_max->{$contract_category} // $market_max->{default_contract_category};

            for my $currency (@$currencies) {
                my $min_stake  = $cat_min->{$currency};
                my $max_payout = $cat_max->{$currency};
                $limits->{$market}->{$currency}->{max_payout} = $max_payout;
                $limits->{$market}->{$currency}->{min_stake}  = $min_stake;
            }
        }
    }

    return $limits;
}

sub minimum_payout_limit {
    my ($currency, $lc, $market, $contract_category) = @_;

    return _get_amount_limit('min_payout', $currency, $lc, $market, $contract_category);
}

sub maximum_payout_limit {
    my ($currency, $lc, $market, $contract_category) = @_;

    return _get_amount_limit('max_payout', $currency, $lc, $market, $contract_category);
}

sub minimum_stake_limit {
    my ($currency, $lc, $market, $contract_category) = @_;

    return _get_amount_limit('min_stake', $currency, $lc, $market, $contract_category);
}

sub maximum_stake_limit {
    my ($currency, $lc, $market, $contract_category) = @_;

    return _get_amount_limit('max_stake', $currency, $lc, $market, $contract_category);
}

sub _get_amount_limit {
    my ($amount_type, $currency, $lc, $market, $contract_category) = @_;

    my $config = BOM::Config::quants()->{bet_limits}{$amount_type} // die $amount_type . ' not defined';
    my $by_lc     = (defined $lc     and $config->{$lc})    ? $config->{$lc}    : $config->{'default_landing_company'};
    my $by_market = (defined $market and $by_lc->{$market}) ? $by_lc->{$market} : $by_lc->{'default_market'};
    my $by_cc =
        (defined $contract_category and $by_market->{$contract_category})
        ? $by_market->{$contract_category}
        : $by_market->{'default_contract_category'};

    return $by_cc->{$currency};
}

1;
