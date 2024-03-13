use Object::Pad;

class BOM::OAuth::Passkeys::PasskeysService;

use strict;
use warnings;
use Syntax::Keyword::Try;
use Log::Any           qw( $log );
use List::Util         qw(any);
use BOM::OAuth::Helper qw(exception_string);
use JSON::MaybeUTF8    qw(decode_json_utf8);
use BOM::OAuth::Passkeys::PasskeysClient;

use constant RPC_ERROR_MAP => {
    UserNotFound              => 'PASSKEYS_NOT_FOUND',
    ChallengeExpired          => 'PASSKEYS_NO_AUTHENTICATION',
    AuthenticationNotVerified => 'PASSKEYS_NOT_VERIFIED',
    PasskeysOff               => 'PASSKEYS_OFF',
    WrongResponse             => 'PASSKEYS_SERVICE_ERROR',
    InternalServerError       => 'PASSKEYS_SERVICE_ERROR',
};

use constant PASSKEYS_ERROR_CODES => {
    'PASSKEYS_NOT_FOUND'         => 400,
    'PASSKEYS_NO_AUTHENTICATION' => 400,
    'PASSKEYS_OFF'               => 400,
    'PASSKEYS_NOT_VERIFIED'      => 400,
    'PASSKEYS_SERVICE_ERROR'     => 500,
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

method get_options ($request_details) {
    try {
        return $passkeys_client->passkeys_options($request_details);
    } catch ($e) {
        die $self->map_error($e);
    }
}

=head2 get_user_details

Communicates with passkeys service to verify the user authentication response.
Returns a hashref of bianry_user_id and verified (will be ignored)

=over 4

=item * $payload - The payload of the request. should contain authenticator response.

=back

=cut

method get_user_details ($payload, $request_details) {

    my $pub_key;
    if ($payload && !ref $payload) {
        try {
            $pub_key = decode_json_utf8($payload);
        } catch ($e) {
            die +{
                code   => 'INVALID_FIELD_VALUE',
                status => 400
            };
        }
    } else {
        $pub_key = $payload;
    }

    if (!$pub_key) {
        die +{
            code   => 'INVALID_FIELD_VALUE',
            status => 400
        };
    }

    my $user_details;
    try {
        $user_details = $passkeys_client->passkeys_login($pub_key, $request_details);
    } catch ($e) {
        die $self->map_error($e);
    }

    if (!($user_details && $user_details->{binary_user_id})) {
        die +{
            code   => 'NO_USER_IDENTITY',
            status => 400
        };
    }
    return $user_details;
}

=head2 map_error

Maps the error returned from passkeys service to the error code of the API.

Any unexpected error is considered as failure to receive the identity of user.

=cut

method map_error ($ex) {
    if (ref $ex eq 'HASH' && $ex->{code} && RPC_ERROR_MAP->{$ex->{code}}) {
        return {
            code   => RPC_ERROR_MAP->{$ex->{code}},
            status => PASSKEYS_ERROR_CODES->{RPC_ERROR_MAP->{$ex->{code}}}};
    }

    die +{
        code            => 'PASSKEYS_SERVICE_ERROR',
        status          => 500,
        additional_info => exception_string($ex)};
}

1;
