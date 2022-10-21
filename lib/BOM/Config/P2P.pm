package BOM::Config::P2P;

use strict;
use warnings;

=head1 NAME

C<BOM::Config::P2P>

=head1 DESCRIPTION

P2P runtime configuration derived from multiple sources.

=cut

use BOM::Config;
use BOM::Config::Runtime;
use LandingCompany::Registry;
use JSON::MaybeUTF8 qw(:v1);
use List::Util      qw(any);

=head2 available_countries

Returns hashref of all countries where P2P is available.
Is not affected by system level suspend of P2P.

=cut

sub available_countries {
    my $p2p_config = BOM::Config::Runtime->instance->app_config->payments->p2p;

    my @enabled_lc           = map { $_->{short} } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;
    my $all_countries        = BOM::Config->brand->countries_instance->countries_list;
    my $available            = $p2p_config->available;
    my @restricted_countries = $p2p_config->restricted_countries->@*;

    my $result = {};
    for my $country (keys %$all_countries) {
        next unless any { $_ eq $all_countries->{$country}{financial_company} or $_ eq $all_countries->{$country}{gaming_company} } @enabled_lc;
        next if any     { $_ eq $country } @restricted_countries;
        next unless $available;
        $result->{$country} = $all_countries->{$country}{name};
    }

    return $result;
}

=head2 advert_config

Return a hashref of floating and fixed rate advert configuration for all P2P countries.

=cut

sub advert_config {
    my $countries = available_countries();

    my $advert_config = decode_json_utf8(BOM::Config::Runtime->instance->app_config->payments->p2p->country_advert_config);

    my $result = {};
    for my $country (keys %$countries) {
        $result->{$country}{float_ads}        = $advert_config->{$country}{float_ads} // 'disabled';
        $result->{$country}{fixed_ads}        = $advert_config->{$country}{fixed_ads} // 'enabled';
        $result->{$country}{deactivate_fixed} = $advert_config->{$country}{deactivate_fixed};
    }

    return $result;
}

=head2 currency_float_range

Returns the allowed rate range for floating rate adverts for a single currency.

=cut

sub currency_float_range {
    my $currency = shift;

    my $currency_config  = decode_json_utf8(BOM::Config::Runtime->instance->app_config->payments->p2p->currency_config);
    my $global_max_range = BOM::Config::Runtime->instance->app_config->payments->p2p->float_rate_global_max_range;
    return $currency_config->{$currency}{max_rate_range} // $global_max_range;
}

1;
