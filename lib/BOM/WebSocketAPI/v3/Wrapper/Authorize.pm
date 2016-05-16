package BOM::WebSocketAPI::v3::Wrapper::Authorize;

use strict;
use warnings;

use BOM::WebSocketAPI::CallingEngine;

sub logout_success {
    my ($c, $args, $rpc_response) = @_;
    my %stash;
    @stash{qw/ loginid email token token_type account_id currency landing_company_name country /} = ();
    $c->stash(%stash);
    return;
}

1;
