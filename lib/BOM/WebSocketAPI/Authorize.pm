package BOM::WebSocketAPI::Authorize;

use strict;
use warnings;

use BOM::Platform::SessionCookie;

sub authorize {
    my ($c, $token) = @_;
    my $session = BOM::Platform::SessionCookie->new(token => $token);
    if (!$session || !$session->validate_session()) {
        return;
    }

    my $email   = $session->email;
    my $loginid = $session->loginid;
    my $client  = BOM::Platform::Client->new({loginid => $loginid});
    my $account = $client->default_account;

    $c->stash(
        token   => $token,
        client  => $client,
        account => $account,
        email   => $email
    );

    return ($client, $account, $email, $loginid);
}

1;
