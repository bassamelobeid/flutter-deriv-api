package BOM::RPC::v3::Static;

use strict;
use warnings;

use LandingCompany::Countries;

use BOM::Platform::Runtime;
use BOM::Platform::Locale;
use BOM::Platform::Context qw (request);
use BOM::RPC::v3::Utility;

sub residence_list {
    my $residence_countries_list;

    my $lc_countries = LandingCompany::Countries->new(brand => request()->brand);
    my $countries = $lc_countries->countries;
    foreach my $country_selection (
        sort { $a->{translated_name} cmp $b->{translated_name} }
        map { +{code => $_, translated_name => $countries->localized_code2country($_, request()->language)} } $countries->all_country_codes
        )
    {
        my $country_code = $country_selection->{code};
        next if $country_code eq '';
        my $country_name = $country_selection->{translated_name};
        my $phone_idd    = $countries->idd_from_code($country_code);
        if (length $country_name > 26) {
            $country_name = substr($country_name, 0, 26) . '...';
        }

        my $option = {
            value => $country_code,
            text  => $country_name,
            $phone_idd ? (phone_idd => $phone_idd) : ()};

        # to be removed later - JP
        if ($lc_countries->restricted_country($country_code) or $country_code eq 'jp') {
            $option->{disabled} = 'DISABLED';
        } elsif (request()->country_code eq $country_code) {
            $option->{selected} = 'selected';
        }
        push @$residence_countries_list, $option;
    }

    return $residence_countries_list;
}

sub states_list {
    my $params = shift;

    my $states = BOM::Platform::Locale::get_state_option($params->{args}->{states_list});
    $states = [grep { $_->{value} ne '' } @$states];
    return $states;
}

sub website_status {
    my $params = shift;

    return {
        terms_conditions_version => BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version,
        api_call_limits          => BOM::RPC::v3::Utility::site_limits,
        clients_country          => $params->{country_code},
        supported_languages      => BOM::Platform::Runtime->instance->app_config->cgi->supported_languages
    };
}

1;
