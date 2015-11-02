package BOM::WebSocketAPI::v3::Authorize;

use strict;
use warnings;

use BOM::Platform::SessionCookie;
use BOM::Platform::Client;
use BOM::Database::Model::AccessToken;
use BOM::Platform::Context qw(localize);

sub authorize {
    my ($c, $args) = @_;

    my $token = $args->{authorize};

    my $err = $c->new_error('authorize', 'InvalidToken', localize('Token invalid'));

    my $loginid;
    my $token_type = 'session_token';
    if (length $token == 15) {    # access token
        my $m = BOM::Database::Model::AccessToken->new;
        $loginid = $m->get_loginid_by_token($token);
        return $err unless $loginid;
        $token_type = 'api_token';
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
        loginid    => $loginid,
        token_type => $token_type,
        client     => $client,
        account    => $account,
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
