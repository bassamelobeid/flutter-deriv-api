package BOM::WebSocketAPI::v3::Wrapper::Authorize;

use strict;
use warnings;

use BOM::WebSocketAPI::CallingEngine;

sub logout_success {
    my ($c, $args, $rpc_response) = @_;
    $c->stash(
        loginid              => undef,
        email                => undef,
        token                => undef,
        token_type           => undef,
        account_id           => undef,
        currency             => undef,
        landing_company_name => undef,
        country              => undef
    );
    return;
}

1;
