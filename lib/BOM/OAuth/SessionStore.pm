use Object::Pad;

class BOM::OAuth::SessionStore;

use strict;
use warnings;
use MIME::Base64    qw(encode_base64 decode_base64);
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);

use constant OFFICIAL_SESSION_COOKIE_NAME => '_osid';
use constant OFFICIAL_SESSION_EXPIRY      => 60 * 60 * 24 * 60;    # 60 days, oauth tokens are valid for 60 days.

field $data;
field $expire_at;
field $c;
field $loginids;

=head2 BUILD

Creates a new instance of the session store. and loads the session.

=over 4

=item c - the controller object.

=back

=cut

BUILD {
    my %args = @_;
    $c         = $args{c};
    $data      = {};
    $expire_at = -1;
    $loginids  = [];
    $self->load_session();
}

=head2 app_ids

Returns the app ids of the current session.

=cut

method app_ids () {
    return [keys $data->%*];
}

=head2 set_session

Set the session for the given app id.

=over 4

=item * C<$app_id> - the official app id.

=item * C<$session> - the session data.

=back

=cut

method set_session ($app_id, $session) {
    if (ref $session eq 'ARRAY') {
        $session = {$session->@*};
    }
    $data->{$app_id} = $session;
}

=head2 load_session

Load the session from the cookie.

=cut

method load_session () {
    my $cookie_string = $c->signed_cookie(OFFICIAL_SESSION_COOKIE_NAME);
    if ($cookie_string) {
        my $cookie_data = decode_json_utf8(decode_base64($cookie_string));
        my $app_ids     = $cookie_data->{apps};
        $expire_at = $cookie_data->{expires_at};
        for my $app_id ($app_ids->@*) {
            my $app_data = $c->signed_cookie(OFFICIAL_SESSION_COOKIE_NAME . "_" . $app_id);
            $data->{$app_id} = decode_json_utf8(decode_base64($app_data));
        }
    }
}

=head2 store_session

Store the session in the cookie.

=over 4

=item * is_new - whether to set new expiry time or use the current sesison expiry time.

=back

=cut

method store_session ($args = {}) {
    my $app_ids = $self->app_ids;
    my $expiry  = $args->{is_new} ? time + OFFICIAL_SESSION_EXPIRY : $expire_at;
    my $attr    = {
        secure   => 1,
        httponly => 1,
        expires  => $expiry,    #we don't need to update the expiry for current session
    };
    my $payload = {
        apps       => $app_ids,
        expires_at => $expiry
    };

    # store the session manager in the cookie
    $c->signed_cookie(OFFICIAL_SESSION_COOKIE_NAME, encode_base64(encode_json_utf8($payload), ''), $attr);

    # store a session cookie for each app id
    for my $app_id ($app_ids->@*) {
        $c->signed_cookie(OFFICIAL_SESSION_COOKIE_NAME . "_" . $app_id, encode_base64(encode_json_utf8($data->{$app_id}), ''), $attr);
    }
}

=head2 get_session_for_app

Get the session for the given app id.
The store should hold a token for each of the loginids of the clients.
If the number of tokens is not equal to the number of clients, then the session is not valid.
This happen if the user created a new account since the last session. in this case we return empty list.

=over 4

=item * C<$app_id> - the app id to retrieve the session for.

=item * C<$clients> - the clients.

=back

=cut

method get_session_for_app ($app_id, $clients) {
    # not strict matching, if the number match it's good enough to tell no new account created.
    if (scalar $clients->@* == scalar grep { /acct/ } (keys $data->{$app_id}->%*)) {
        return ($data->{$app_id}->%*);
    }
    return ();
}

=head2 clear_session

Remove the official session cookie by setting it to expire.

=cut

method clear_session () {
    $c->signed_cookie(OFFICIAL_SESSION_COOKIE_NAME, '', {expires => 1});

    map { $c->signed_cookie(OFFICIAL_SESSION_COOKIE_NAME . "_" . $_, '', {expires => 1}); } $self->app_ids->@*;
}

=head2 is_valid_session

The session is valid if all tokens are valid no matter the app id. (logged out from app.deriv.com means logged out from api.deriv.com)

=cut 

method is_valid_session () {
    return 0 if !$self->has_session;
    my $oauth_model = BOM::Database::Model::OAuth->new;
    for my $tokens_details (values $data->%*) {
        for my $key ($tokens_details->%*) {
            if ($key !~ /token/) {
                next;
            }
            my $token_details = $oauth_model->get_token_details($tokens_details->{$key});
            if (!$token_details->{loginid}) {
                $loginids = [];
                return 0;
            }
            push $loginids->@*, $token_details->{loginid};
        }
    }
    return 1;
}

=head2 get_loginid

Get random (first) login id from the session.
Should be called only if the sesison is valid.

=cut

method get_loginid () {
    return $loginids->[0];
}

=head2 has_session

Check if the session has any app id.

=cut

method has_session () {
    return $self->app_ids()->@* > 0;
}

1;
