package BOM::WebSocketAPI::v3::Static;

use strict;
use warnings;

use BOM::Web::Form;

sub states_list {
    my ($c, $args) = @_;

    my $country = $args->{states_list};
    my $states  = BOM::Web::Form::get_state_option($country);
    $states = [grep { $_->{value} ne '' } @$states];
    return {
        msg_type    => 'states_list',
        states_list => $states,
    };
}

1;
