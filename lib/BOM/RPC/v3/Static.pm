package BOM::RPC::v3::Static;

use strict;
use warnings;

use BOM::Platform::Runtime;
use BOM::Platform::Countries;
use BOM::Platform::Locale;
use BOM::Platform::Context qw (request);
use BOM::RPC::v3::Utility;

sub residence_list {
    my $params = shift;

    my $residence_list = BOM::Platform::Locale::generate_residence_countries_list();
    $residence_list = [grep { $_->{value} ne '' } @$residence_list];

    # plus phone_idd
    my $countries = BOM::Platform::Countries->instance->countries;
    foreach (@$residence_list) {
        my $phone_idd = $countries->idd_from_code($_->{value});
        $_->{phone_idd} = $phone_idd if $phone_idd;
    }

    return $residence_list;
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
