package Binary::WebSocketAPI::v3::Wrapper::Authorize;

use strict;
use warnings;

use Mojo::IOLoop;
use Scalar::Util qw(weaken);

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

    # persist actual limits every 15m for logged-in users
    $c->stash->{rate_limitations_timer} = Mojo::IOLoop->recurring(
        15 * 60 => sub {
            weaken $c;
            $c->rate_limitations_save;
        });
    return;
}

1;
