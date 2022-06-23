package BOM::Config::Quants;

use strict;
use warnings;

=head1 NAME

C<BOM::Config::Quants>

=head1 DESCRIPTION

This module exports methods to get our quants and trading configuration.

=cut

use DataDog::DogStatsd::Helper qw(stats_inc);

use Exporter qw(import);
our @EXPORT_OK = qw(market_pricing_limits minimum_payout_limit maximum_payout_limit minimum_stake_limit maximum_stake_limit);

=head2 market_pricing_limits

Takes the following argument(s):

=over 4

=item * C<$currencies> - An arrayref of currency codes

=item * C<$lc> - The landing company shortcode as a string

=item * C<$markets> - An arrayref of market types

=item * C<$contract_categories> - An arrayref of contract categories

=back

Returns the hashref of market pricing limits for desired market, landing company,
contract category and currency combination.

=cut

sub market_pricing_limits {
    my ($currencies, $lc, $markets, $contract_categories) = @_;

    $lc                  ||= "default_landing_company";
    $markets             ||= ["default_market"];
    $contract_categories ||= ['default_contract_category'];

    my $config = BOM::Config::quants()->{bet_limits};
    my $lc_min = $config->{min_stake}->{$lc}  || $config->{min_stake}->{default_landing_company};
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

                if (not defined $min_stake or not defined $max_payout) {
                    stats_inc('bom_config.quants.market_pricing_limits.unsupported_currency', {tags => ['currency:' . $currency]});
                }

                $limits->{$market}->{$currency}->{max_payout} = $max_payout + 0
                    if defined $max_payout;    #add plus 0 to ensure it will always be a number instead of string
                $limits->{$market}->{$currency}->{min_stake} = $min_stake + 0 if defined $min_stake;
            }
        }
    }

    return $limits;
}

=head2 minimum_payout_limit

Takes the following argument(s):

=over 4

=item * C<$currency> - ISO currency code as a string

=item * C<$lc> - The landing company shortcode as a string

=item * C<$market> - Market type as a string

=item * C<$contract_category> - The contract category as a string

=back

Returns the minimum payout limit for the desired currency, landing company,
market and contract category combination.

=cut

sub minimum_payout_limit {
    my ($currency, $lc, $market, $contract_category) = @_;

    return _get_amount_limit('min_payout', $currency, $lc, $market, $contract_category);
}

=head2 maximum_payout_limit

Takes the following argument(s):

=over 4

=item * C<$currency> - ISO currency code as a string

=item * C<$lc> - The landing company shortcode as a string

=item * C<$market> - Market type as a string

=item * C<$contract_category> - The contract category as a string

=back

Returns the maximum payout limit for the desired currency, landing company,
market and contract category combination.

=cut

sub maximum_payout_limit {
    my ($currency, $lc, $market, $contract_category) = @_;

    return _get_amount_limit('max_payout', $currency, $lc, $market, $contract_category);
}

=head2 minimum_stake_limit

Takes the following argument(s):

=over 4

=item * C<$currency> - ISO currency code as a string

=item * C<$lc> - The landing company shortcode as a string

=item * C<$market> - Market type as a string

=item * C<$contract_category> - The contract category as a string

=back

Returns the minimum stake limit for the desired currency, landing company,
market and contract category combination.

=cut

sub minimum_stake_limit {
    my ($currency, $lc, $market, $contract_category) = @_;

    return _get_amount_limit('min_stake', $currency, $lc, $market, $contract_category);
}

=head2 maximum_stake_limit

Takes the following argument(s):

=over 4

=item * C<$currency> - ISO currency code as a string

=item * C<$lc> - The landing company shortcode as a string

=item * C<$market> - Market type as a string

=item * C<$contract_category> - The contract category as a string

=back

Returns the maximum payout limit for the desired currency, landing company,
market and contract category combination.

=cut

sub maximum_stake_limit {
    my ($currency, $lc, $market, $contract_category) = @_;

    return _get_amount_limit('max_stake', $currency, $lc, $market, $contract_category);
}

sub _get_amount_limit {
    my ($amount_type, $currency, $lc, $market, $contract_category) = @_;

    my $config    = BOM::Config::quants()->{bet_limits}{$amount_type} // die $amount_type . ' not defined';
    my $by_lc     = (defined $lc     and $config->{$lc})    ? $config->{$lc}    : $config->{'default_landing_company'};
    my $by_market = (defined $market and $by_lc->{$market}) ? $by_lc->{$market} : $by_lc->{'default_market'};
    my $by_cc =
        (defined $contract_category and $by_market->{$contract_category})
        ? $by_market->{$contract_category}
        : $by_market->{'default_contract_category'};

    return $by_cc->{$currency};
}

1;
