package BOM::WebSocketAPI::Authorize;

use strict;
use warnings;

use BOM::Platform::SessionCookie;
use BOM::Platform::Client;

sub authorize {
    my ($c, $token) = @_;
    my $session = BOM::Platform::SessionCookie->new(token => $token);
    if (!$session || !$session->validate_session()) {
        return;
    }

    my $loginid = $session->loginid;
    my $client  = BOM::Platform::Client->new({loginid => $loginid});
    return unless $client;

    my $email   = $session->email;
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
