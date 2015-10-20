package BOM::WebSocketAPI::v2::Authorize;

use strict;
use warnings;

use BOM::Platform::SessionCookie;
use BOM::Platform::Client;
use BOM::Database::Model::AccessToken;

sub authorize {
    my ($c, $args) = @_;

    my $token = $args->{authorize};

    my $err = {
        msg_type => 'authorize',
        error    => {
            message => "Token invalid",
            code    => "InvalidToken"
        }};

    my $loginid;
    if (length $token == 15) {    # access token
        my $m = BOM::Database::Model::AccessToken->new;
        $loginid = $m->get_loginid_by_token($token);
        return $err unless $loginid;
    } else {
        my $session = BOM::Platform::SessionCookie->new(token => $token);
        if (!$session || !$session->validate_session()) {
            return $err;
        }

        $loginid = $session->loginid;
    }

    my $client = BOM::Platform::Client->new({loginid => $loginid});
    return $err unless $client;

    my $email   = $client->email;
    my $account = $client->default_account;

    $c->stash(
        token   => $token,
        client  => $client,
        account => $account,
        email   => $email
    );

    return {
        msg_type  => 'authorize',
        authorize => {
            fullname => $client->full_name,
            loginid  => $client->loginid,
            balance  => ($account ? $account->balance : 0),
            currency => ($account ? $account->currency_code : ''),
            email    => $email,
        },
    };
}

1;
