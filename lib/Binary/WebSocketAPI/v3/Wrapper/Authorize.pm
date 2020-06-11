package Binary::WebSocketAPI::v3::Wrapper::Authorize;

use strict;
use warnings;

use curry::weak;
use Mojo::IOLoop;
use Scalar::Util qw(weaken);
use Log::Any qw($log);
use Binary::WebSocketAPI::v3::Wrapper::System;

sub logout_success {
    my $c = shift;
    my %stash;

    Binary::WebSocketAPI::v3::Wrapper::System::forget_after_logout($c);

    @stash{qw/ loginid email token token_type account_id currency landing_company_name/} = ();
    $c->stash(%stash);
    return;
}

sub login_success {
    my ($c, $rpc_response) = @_;

    local $log->context->{rpc_response} = $rpc_response;
    $log->error("landing_company_name in rpc_response is undef after login")
        unless $rpc_response->{landing_company_name} and $rpc_response->{stash}{landing_company_name};
    # rpc response is not yet populated into stash
    $c->stash(loginid              => $rpc_response->{loginid});
    $c->stash(landing_company_name => $rpc_response->{landing_company_name});
    # stash "country_code" will already be populated with IP country, so "residence" is used instead
    $c->stash(residence => $rpc_response->{country});

    return;
}

1;
