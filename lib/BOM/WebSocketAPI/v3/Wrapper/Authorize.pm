package BOM::WebSocketAPI::v3::Wrapper::Authorize;

use strict;
use warnings;

use BOM::WebSocketAPI::Websocket_v3;

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
                my $token_type = 'session_token';
                if (length $token == 15) {
                    $token_type = 'api_token';
                } elsif (length $token == 32 && $token =~ /^a1-/) {
                    $token_type = 'oauth_token';
                }

                $c->stash(
                    loginid              => $response->{loginid},
                    email                => $response->{email},                  # to logging user logout
                    token                => $token,
                    token_type           => $token_type,
                    token_scopes         => $response->{scopes},
                    account_id           => delete $response->{account_id},
                    currency             => $response->{currency},
                    landing_company_name => $response->{landing_company_name},
                    country              => delete $response->{country},
                    is_virtual           => $response->{is_virtual});
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

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c, 'logout',
        sub {
            my $response = shift;

            $c->stash(
                loginid              => undef,
                email                => undef,
                token                => undef,
                token_type           => undef,
                account_id           => undef,
                currency             => undef,
                landing_company_name => undef,
                country              => undef
            );

            return {
                msg_type => 'logout',
                logout   => $response->{status}};
        },
        {
            args         => $args,
            token        => $c->stash('token'),
            token_type   => $c->stash('token_type'),
            client_email => $c->stash('email'),
            client_ip    => $c->client_ip,
            country_code => $c->country_code,
            language     => $c->stash('language'),
            user_agent   => $c->req->headers->header('User-Agent')});
    return;
}

1;
