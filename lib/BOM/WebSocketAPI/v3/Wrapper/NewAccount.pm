package BOM::WebSocketAPI::v3::Wrapper::NewAccount;

use strict;
use warnings;

use BOM::WebSocketAPI::v3::NewAccount;
use BOM::Platform::SessionCookie;

sub new_account_virtual {
    my ($c, $args) = @_;

    my $token = $c->cookie('verify_token') || $args->{verification_code};

    my $response = BOM::WebSocketAPI::v3::NewAccount::new_account_virtual($args, $token, $args->{email});
    if (exists $response->{error}) {
        return $c->new_error('new_account_virtual', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type            => 'new_account_virtual',
            new_account_virtual => $response
        };
    }
}

sub verify_email {
    my ($c, $args) = @_;
    my $r = $c->stash('request');

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

    my $response = BOM::WebSocketAPI::v3::NewAccount::verify_email($email, $c->stash('request')->website, $link);

    return {
        msg_type     => 'verify_email',
        verify_email => 1
    };
}

sub new_account_real {
    my ($c, $args) = @_;

    my $response = BOM::WebSocketAPI::v3::NewAccount::new_account_real($c->stash('client'), $args);
    if (exists $response->{error}) {
        return $c->new_error('new_account_real', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type         => 'new_account_real',
            new_account_real => $response
        };
    }
    return;
}

sub new_account_maltainvest {
    my ($c, $args) = @_;

    my $response = BOM::WebSocketAPI::v3::NewAccount::new_account_maltainvest($c->stash('client'), $args);
    if (exists $response->{error}) {
        return $c->new_error('new_account_maltainvest', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type                => 'new_account_maltainvest',
            new_account_maltainvest => $response
        };
    }
    return;
}

1;
