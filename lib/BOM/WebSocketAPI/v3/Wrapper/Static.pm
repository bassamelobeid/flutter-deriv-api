package BOM::WebSocketAPI::v3::Wrapper::Static;

use strict;
use warnings;

use BOM::RPC::v3::Static;

sub residence_list {
    my ($c, $args) = @_;

    return {
        msg_type       => 'residence_list',
        residence_list => BOM::RPC::v3::Static::residence_list(),
    };
}

sub states_list {
    my ($c, $args) = @_;

    return {
        msg_type    => 'states_list',
        states_list => BOM::RPC::v3::Static::states_list($args->{states_list}),
    };
}

1;
