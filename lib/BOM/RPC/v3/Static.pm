package BOM::RPC::v3::Static;

use strict;
use warnings;

use BOM::Platform::Locale;

sub residence_list {
    my $residence_list = BOM::Platform::Locale::generate_residence_countries_list();
    $residence_list = [grep { $_->{value} ne '' } @$residence_list];
    return $residence_list,;
}

sub states_list {
    my $country = shift;

    my $states = BOM::Platform::Locale::get_state_option($country);
    $states = [grep { $_->{value} ne '' } @$states];
    return $states;
}

1;
