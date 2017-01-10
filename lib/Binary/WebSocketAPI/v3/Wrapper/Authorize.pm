package Binary::WebSocketAPI::v3::Wrapper::Authorize;

use strict;
use warnings;

sub logout_success {
    my ($c, $rpc_response) = @_;
    my %stash;
    $c->rate_limitations_save;
    @stash{qw/ loginid email token token_type account_id currency landing_company_name /} = ();
    $c->stash(%stash);
    return;
}

sub login_success {
    my ($c, $rpc_response) = @_;
    $c->rate_limitations_load;
    return;
}


1;
