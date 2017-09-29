package Binary::WebSocketAPI::v3::Wrapper::Authorize;

use strict;
use warnings;

use curry::weak;
use Mojo::IOLoop;
use Scalar::Util qw(weaken);
use Binary::WebSocketAPI::v3::Wrapper::System;
sub warn1 {
        open Q, ">>/tmp/qwe";
            print Q @_,"\n";
                close Q;
            }

sub logout_success {
    my $c = shift;
    my %stash;
warn1 "** logout_success";
    Binary::WebSocketAPI::v3::Wrapper::System::forget_after_logout($c);

    @stash{qw/ loginid email token token_type account_id currency landing_company_name /} = ();
    $c->stash(%stash);
    return;
}

sub login_success {
    my ($c, $rpc_response) = @_;
warn1 "** login_success";

    # rpc response is not yet populated into stash
    $c->stash(loginid              => $rpc_response->{loginid});
    $c->stash(landing_company_name => $rpc_response->{landing_company_name});

    return;
}

1;
