package BOM::WebSocketAPI::v3::Wrapper::Authorize;

use strict;
use warnings;

use BOM::WebSocketAPI::Websocket_v3;
use BOM::Platform::Client;

sub authorize {
    my ($c, $args) = @_;

    my $token = $args->{authorize};
    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'authorize',
        sub {
            my $response = shift;
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
                    authorize => $response,
                };
            }
        },
        {
            args  => $args,
            token => $token
        });
    return;
}

sub logout {
    my ($c, $args) = @_;

    my $r = $c->stash('request');
    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c, 'logout',
        sub {
            my $response = shift;

            # Invalidates token, but we can only do this if we have a cookie
            $r->session_cookie->end_session if $r->session_cookie;

            $c->stash(
                loginid    => undef,
                token_type => undef,
                client     => undef,
                account    => undef
            );

            return {
                msg_type => 'logout',
                logout   => $response->{status}};
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid'),
            client_email   => $r->email,
            client_ip      => $r->client_ip,
            country_code   => $r->country_code,
            language       => $r->language,
            user_agent     => $c->req->headers->header('User-Agent')});
    return;
}

1;
