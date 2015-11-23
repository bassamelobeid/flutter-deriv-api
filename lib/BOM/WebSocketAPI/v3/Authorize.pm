package BOM::WebSocketAPI::v3::Authorize;

use strict;
use warnings;

use BOM::WebSocketAPI::v3::Utility;

use BOM::Platform::Client;
use BOM::Platform::SessionCookie;
use BOM::Platform::Context qw (localize);
use BOM::Database::Model::AccessToken;

sub authorize {
    my $token = shift;

    my $err = BOM::WebSocketAPI::v3::Utility::create_error('authorize', 'InvalidToken', BOM::Platform::Context::localize('The token is invalid.'));

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

    my $account = $client->default_account;

    return {
        fullname => $client->full_name,
        loginid  => $client->loginid,
        balance  => ($account ? $account->balance : 0),
        currency => ($account ? $account->currency_code : ''),
        email    => $client->email,
    };
}

1;
