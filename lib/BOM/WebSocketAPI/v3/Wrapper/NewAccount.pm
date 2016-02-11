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
    my $type  = $args->{type};

    my $link;
    my $code;
    if ($type eq 'account_opening') {
        $code = BOM::Platform::SessionCookie->new({
                email       => $email,
                expires_in  => 3600,
                created_for => 'new_account'
            })->token;
    } elsif ($type eq 'lost_password') {
        $code = BOM::Platform::SessionCookie->new({
                email       => $email,
                expires_in  => 3600,
                created_for => 'lost_password'
            })->token;
    } elsif ($type eq 'payment_agent_withdrawal') {
        $code = BOM::Platform::SessionCookie->new({
                email       => $email,
                expires_in  => 3600,
                created_for => 'payment_agent_withdrawal'
            })->token;
    }
    $link = $r->url_for(
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
            website_name => $r->website->display_name,
            link         => $link->to_string,
            type         => $type
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
            token          => $c->stash('token'),
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
            token          => $c->stash('token'),
            client_loginid => $c->stash('loginid')});
    return;
}

sub new_account_japan {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'new_account_japan',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('new_account_japan', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type          => 'new_account_japan',
                    new_account_japan => $response
                };
            }
        },
        {
            args           => $args,
            token          => $c->stash('token'),
            client_loginid => $c->stash('loginid')});
    return;
}

1;
