package BOM::WebSocketAPI::v3::Wrapper::Authorize;

use strict;
use warnings;

use BOM::WebSocketAPI::v3::Authorize;
use BOM::Platform::Client;

sub authorize {
    my ($c, $args) = @_;
    my $token = $args->{authorize};

    my $response = BOM::WebSocketAPI::v3::Authorize::authorize($token);

    if (exists $response->{error}) {
        return $c->new_error('authorize', $response->{error}->{code}, $response->{error}->{message});
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
            authorize => {%$response}};
    }

    return;
}

1;
