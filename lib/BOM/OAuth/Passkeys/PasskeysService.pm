use Object::Pad;

class BOM::OAuth::Passkeys::PasskeysService;

use strict;
use warnings;
use Syntax::Keyword::Try;
use Log::Any           qw( $log );
use List::Util         qw(any);
use BOM::OAuth::Helper qw(exception_string);
use BOM::OAuth::Passkeys::PasskeysClient;

use constant RPC_ERROR_MAP => {
    UserNotFound              => 'PASSKEYS_NOT_FOUND',
    AuthenticationNotVerified => 'PASSKEYS_NO_AUTHENTICATION',
    ChallengeExpired          => 'PASSKEYS_NO_AUTHENTICATION',
};

field $passkeys_client;

=head2 new 

Creates a new instance of the service.

=cut

BUILD {
    $passkeys_client = BOM::OAuth::Passkeys::PasskeysClient->new;
}

=head2 get_options

Returns the passkeys options.

=cut

method get_options {
    return $passkeys_client->passkeys_options();
}

=head2 login

Communicates with passkeys service to verify the user authentication response.
Returns the login result.

=over 4

=item * $c - The mojo controller.

=item * $payload - The payload of the request. should contain authenticator response.

=item * $app - The app object.

=back

=cut

method login ($c, $payload, $app) {

    my $pub_key = $payload->{publicKeyCredential};

    if (!$pub_key) {
        die +{
            code   => 'INVALID_FIELD_VALUE',
            status => 400
        };
    }

    my $user_details;
    try {
        $user_details = $passkeys_client->passkeys_login($pub_key);
    } catch ($e) {
        die $self->to_login_error($e);
    }

    if (!($user_details && $user_details->{binary_user_id})) {
        die +{
            code   => 'NO_USER_IDENTITY',
            status => 500
        };
    }

    my $result = BOM::OAuth::Common::validate_login({
        c                => $c,
        app              => $app,
        passkeys_user_id => $user_details->{binary_user_id},
        device_id        => $c->req->param('device_id'),
    });

    return $result;
}

=head2 to_login_error

Maps the error returned from passkeys service to the error code of the API.

Any unexpected error is considered as failure to receive the identity of user.

=cut

method to_login_error ($ex) {
    if (ref $ex eq 'HASH' && $ex->{code} && RPC_ERROR_MAP->{$ex->{code}}) {
        return {
            code   => RPC_ERROR_MAP->{$ex->{code}},
            status => 400
        };
    }

    die +{
        code            => 'NO_USER_IDENTITY',
        status          => 500,
        additional_info => exception_string($ex)};
}

1;
