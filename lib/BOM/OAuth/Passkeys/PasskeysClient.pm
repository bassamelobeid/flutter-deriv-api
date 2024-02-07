use Object::Pad;

class BOM::OAuth::Passkeys::PasskeysClient;

use strict;
use warnings;
use BOM::Config;
use BOM::Transport::RedisAPI;
use Syntax::Keyword::Try;

field $redis_api;

=head2 new

Creates a new instance of the class.

=cut

=head2 redis_api

Caches and returns the cached RedisApi instance.

=cut

method redis_api {
    return $redis_api //= BOM::Transport::RedisAPI->new(
        redis_config => BOM::Config::redis_rpc_config()->{write},
        req_category => 'passkeys'
    );
}

=head2 passkeys_options

Returns the passkeys options.
It'll die in case of RPC error. or unexpected response.

=cut

method passkeys_options {
    my $request  = $self->redis_api->build_rpc_request('passkeys_options');
    my $response = $self->redis_api->call_rpc($request);

    my $result = $response->{response}->{result};
    if ($result->{error}) {
        die $self->map_rpc_error($result->{error});
    }

    return $result;
}

=head2 passkeys_login

Sends the passkeys_login RPC request and returns the result.
It'll die in case of RPC error.

=over 4

=item * $auth_response - The auth response from the authenticator.

=back

=cut

method passkeys_login ($auth_response) {
    my $request  = $self->redis_api->build_rpc_request('passkeys_login', {publicKeyCredential => $auth_response});
    my $response = $self->redis_api->call_rpc($request);

    my $result = $response->{response}->{result};
    if ($result->{error}) {
        die $self->map_rpc_error($result->{error});
    }

    return $result;
}

=head2 map_rpc_error

Helper function that maps RPC error to a hashref with code and message.

=over 4

=item * $error - RPC error hashref

=back

=cut

method map_rpc_error ($error) {
    return {
        code    => $error->{code},
        message => $error->{message_to_client},
    };
}

1;
