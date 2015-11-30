package BOM::WebSocketAPI::v3::Wrapper::NewAccount;

use strict;
use warnings;

use BOM::WebSocketAPI::v3::NewAccount;

sub new_account_virtual {
    my ($c, $args) = @_;

    my $response = BOM::WebSocketAPI::v3::NewAccount::new_account_virtual($args);
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

    my $email = $args->{verify_email};
    my $response = BOM::WebSocketAPI::v3::NewAccount::verify_email($email, $c->stash('request')->website);
    return {
        msg_type     => 'verify_email',
        verify_email => $response->{status}};
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
