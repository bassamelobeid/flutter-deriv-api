package Binary::WebSocketAPI::v3::Wrapper::Authorize;

use strict;
use warnings;

use curry::weak;
use Mojo::IOLoop;
use Scalar::Util qw(weaken);
use Binary::WebSocketAPI::v3::Wrapper::System;

sub logout_success {
    my $c = shift;
    my %stash;

    Binary::WebSocketAPI::v3::Wrapper::System::forget_after_logout($c);

    @stash{qw/ loginid email token token_type account_id currency landing_company_name country/} = ();
    $c->stash(%stash);
    return;
}

sub login_success {
    my ($c, $rpc_response) = @_;

    # rpc response is not yet populated into stash
    $c->stash(loginid              => $rpc_response->{loginid});
    $c->stash(landing_company_name => $rpc_response->{landing_company_name});
    $c->stash(country              => $rpc_response->{country});

    return;
}

1;
