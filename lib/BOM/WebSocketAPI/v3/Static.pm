package BOM::WebSocketAPI::v3::Static;

use strict;
use warnings;

use BOM::Platform::Locale;

sub residence_list {
    my ($c, $args) = @_;

    my $residence_list = BOM::Platform::Locale::generate_residence_countries_list();
    $residence_list = [grep { $_->{value} ne '' } @$residence_list];
    return {
        msg_type       => 'residence_list',
        residence_list => $residence_list,
    };
}

sub states_list {
    my ($c, $args) = @_;

    my $country = $args->{states_list};
    my $states  = BOM::Platform::Locale::get_state_option($country);
    $states = [grep { $_->{value} ne '' } @$states];
    return {
        msg_type    => 'states_list',
        states_list => $states,
    };
}

1;
