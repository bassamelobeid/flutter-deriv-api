package BOM::WebSocketAPI::v3::Wrapper::Accounts;

use 5.014;
use strict;
use warnings;

use BOM::WebSocketAPI::v3::Accounts;

sub landing_company {
    my ($c, $args) = @_;

    my $response = BOM::WebSocketAPI::v3::Accounts::landing_company($args);
    if (exists $response->{error}) {
        return $c->new_error('landing_company', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type        => 'landing_company',
            landing_company => $response,
        };
    }
}

sub landing_company_details {
    my ($c, $args) = @_;

    my $response = BOM::WebSocketAPI::v3::Accounts::landing_company($args);
    if (exists $response->{error}) {
        return $c->new_error('landing_company_details', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type                => 'landing_company_details',
            landing_company_details => $response
        };
    }
}

sub statement {
    my ($c, $args) = @_;

    return {
        echo_req  => $args,
        msg_type  => 'statement',
        statement => BOM::WebSocketAPI::v3::Accounts::statement($c->stash('account'));
        ,
    };
}

sub profit_table {
    my ($c, $args) = @_;

    return {
        echo_req     => $args,
        msg_type     => 'profit_table',
        profit_table => BOM::WebSocketAPI::v3::Accounts::profit_table($c->stash('client')),
    };
}

1;

