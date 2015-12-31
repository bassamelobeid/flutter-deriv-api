package BOM::WebSocketAPI::v3::Wrapper::NewAccount;

use strict;
use warnings;

use BOM::RPC::v3::NewAccount;
use BOM::WebSocketAPI::Websocket_v3;
use BOM::Platform::SessionCookie;

sub new_account_virtual {
    my ($c, $args) = @_;

    my $token = $c->cookie('verify_token') || $args->{verification_code};
    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'new_account_virtual',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('new_account_virtual', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type            => 'new_account_virtual',
                    new_account_virtual => $response
                };
            }
        },
        {
            args  => $args,
            token => $token
        });
    return;
}

sub verify_email {
    my ($c, $args) = @_;

    my $r     = $c->stash('request');
    my $email = $args->{verify_email};

    my $code = BOM::Platform::SessionCookie->new({
            email       => $email,
            expires_in  => 3600,
            created_for => 'new_account'
        })->token;

    my $link = $r->url_for(
        '/user/validate_link',
        {
            verify_token => $code,
        });

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'verify_email',
        sub {
            my $response = shift;
            return {
                msg_type     => 'verify_email',
                verify_email => $response->{status}};
        },
        {
            args         => $args,
            email        => $email,
            cs_email     => $r->website->config->get('customer_support.email'),
            website_name => $r->website->display_name,
            link         => $link->to_string
        });
    return;
}

sub new_account_real {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'new_account_real',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('new_account_real', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type         => 'new_account_real',
                    new_account_real => $response
                };
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid')});
    return;
}

sub new_account_maltainvest {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'new_account_maltainvest',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('new_account_maltainvest', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type                => 'new_account_maltainvest',
                    new_account_maltainvest => $response
                };
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid')});
    return;
}

1;
