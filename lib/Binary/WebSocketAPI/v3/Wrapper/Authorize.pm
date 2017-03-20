package Binary::WebSocketAPI::v3::Wrapper::Authorize;

use strict;
use warnings;

use curry::weak;
use Mojo::IOLoop;
use Scalar::Util qw(weaken);

sub logout_success {
    my ($c, $rpc_response) = @_;
    my %stash;
    $c->rate_limitations_save;

    my $timer_id = $c->stash->{rate_limitations_timer};
    Mojo::IOLoop->remove($timer_id) if $timer_id;

    @stash{qw/ loginid email token token_type account_id currency landing_company_name /} = ();
    $c->stash(%stash);
    return;
}

sub login_success {
    my ($c, $rpc_response) = @_;

    # rpc response is not yet populated into stash
    $c->stash(loginid              => $rpc_response->{loginid});
    $c->stash(landing_company_name => $rpc_response->{landing_company_name});

    $c->rate_limitations_load;

    # persist actual limits every 15m for logged-in users
    $c->stash->{rate_limitations_timer} = Mojo::IOLoop->recurring(15 * 60 => $c->curry::weak::rate_limitations_save);
    return;
}

1;
