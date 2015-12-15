package BOM::WebSocketAPI::v3::Wrapper::Authorize;

use strict;
use warnings;

use BOM::RPC::v3::Authorize;
use BOM::Platform::Client;

sub authorize {
    my ($c, $args) = @_;
    my $token = $args->{authorize};

    my $response = BOM::RPC::v3::Authorize::authorize($token);

    if (exists $response->{error}) {
        return $c->new_error('authorize', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        my $client = BOM::Platform::Client->new({loginid => $response->{loginid}});

        my $token_type = 'session_token';
        if (length $token == 15) {
            $token_type = 'api_token';
        }

        $c->stash(
            loginid    => $response->{loginid},
            token_type => $token_type,
            client     => $client,
            account    => $client->default_account // undef,
        );

        return {
            msg_type  => 'authorize',
            authorize => $response
        };
    }

    return;
}

sub logout {
    my ($c, $args) = @_;

    BOM::RPC::v3::Authorize::logout($c->stash('request'), $c->req->headers->header('User-Agent') || '');

    $c->stash(
        loginid    => undef,
        token_type => undef,
        client     => undef,
        account    => undef
    );

    return {
        msg_type => 'logout',
        logout   => 1
    };
}

1;
