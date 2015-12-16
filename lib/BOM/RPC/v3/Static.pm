package BOM::RPC::v3::Static;

use strict;
use warnings;

use BOM::Platform::Locale;
use BOM::Platform::Context;

sub residence_list {
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    my $residence_list = BOM::Platform::Locale::generate_residence_countries_list();
    $residence_list = [grep { $_->{value} ne '' } @$residence_list];
    return $residence_list,;
}

sub states_list {
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    my $args    = $params->{args};
    my $country = $args->{states_list};

    my $states = BOM::Platform::Locale::get_state_option($country);
    $states = [grep { $_->{value} ne '' } @$states];
    return $states;
}

1;
