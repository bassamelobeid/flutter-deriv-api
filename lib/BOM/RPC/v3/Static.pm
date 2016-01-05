package BOM::RPC::v3::Static;

use strict;
use warnings;

use BOM::Platform::Runtime;
use BOM::Platform::Locale;
use BOM::Platform::Context qw (request);

sub residence_list {
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    my $residence_list = BOM::Platform::Locale::generate_residence_countries_list();
    $residence_list = [grep { $_->{value} ne '' } @$residence_list];

    # plus phone_idd
    my $countries = BOM::Platform::Runtime->instance->countries;
    foreach (@$residence_list) {
        my $phone_idd = $countries->idd_from_code($_->{value});
        $_->{phone_idd} = $phone_idd if $phone_idd;
    }

    return $residence_list;
}

sub states_list {
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    my $states = BOM::Platform::Locale::get_state_option($params->{args}->{states_list});
    $states = [grep { $_->{value} ne '' } @$states];
    return $states;
}

1;
