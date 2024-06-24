package BOM::Service::User::Attributes::Update::SaveHandlersUser;

use strict;
use warnings;
no indirect;

use Cache::LRU;
use Time::HiRes qw(gettimeofday tv_interval);

use BOM::Service;
use BOM::Service::Helpers;
use BOM::Service::User::Attributes;
use BOM::Service::User::Attributes::Get;
use BOM::Service::User::Transitional::Password;
use BOM::Service::User::Transitional::SocialSignup;
use BOM::Service::User::Transitional::TotpFields;
use BOM::User;
use BOM::Database::Model::OAuth;
use BOM::Platform::Event::Emitter;

# A word to the wise on Clients objects vs User objects. The Client object appears a full on rose
# object with all the bells and whistles, and so we should use the getters/setters to ensure the
# object is aware of the changes. The User object is a bit of a kludge and in that case the hash
# access is the way to go.

# We cannot save the user as a single object because there are no methods to update a whole row, just a
# number of methods for specific areas <insert face palm here>. This means we have to save the user in
# parts, which is not ideal but it is what it is. User doesn't appear to have had a lot of TLC.

=head2 save_user_email_verified

This subroutine saves the email_verified field for a user. It first retrieves the user object using the user_id and correlation_id from the request. Then, it calls the local private '_update_email_fields' method, passing the user object and a hash reference containing the 'email_verified' and 'email_consent' attributes of the user.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The changes are saved directly to the user object.

=back

=cut

sub save_user_email_verified {
    my ($request) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    _update_email_fields($user, email_verified => $user->{email_verified});
}

=head2 save_user_email_consent

This subroutine saves the email consent field for a user. It first retrieves the user object using the user_id and correlation_id from the request. Then, it calls the local '_update_email_fields' method, passing the user object and a hash reference containing the 'email_verified' and 'email_consent' attributes of the user.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The changes are saved directly to the user object.

=back

=cut

sub save_user_email_consent {
    my ($request) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    _update_email_fields($user, email_consent => $user->{email_consent});

    # If the email_consent has changed and is false
    my $client = BOM::Service::Helpers::get_client_object($request->{user_id}, $request->{context}->{correlation_id});
    if (!$user->{email_consent}) {
        # After update notify customer io
        my $data_subscription = {
            loginid      => $client->loginid,
            unsubscribed => 0,
        };
        BOM::Platform::Event::Emitter::emit('email_subscription', $data_subscription);
    }
}

=head2 save_user_email

This subroutine updates the email of a user. It first retrieves the user object using the user_id and correlation_id from the request. Then, it updates the email field in the user and clients and removes all tokens.

After updating the email, it retrieves the client object using the same user_id and correlation_id. It then emits events to sync the user to MT5 and sync Onfido details, unless the client is virtual.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The changes are saved directly to the user and client objects.

=back

=cut

sub save_user_email {
    my ($request) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});

    _update_email_fields($user, email => lc $user->{email});
    my $oauth   = BOM::Database::Model::OAuth->new;
    my @clients = $user->clients(
        include_self_closed => 1,
        include_disabled    => 1,
        include_duplicated  => 1,
    );

    # TODO - This needs to go as soon as poss, all access to it is moved to either the user object or service.
    for my $client (@clients) {
        $client->email($user->{email});
        $client->save;
        $oauth->revoke_tokens_by_loginid($client->loginid);
    }

    # revoke refresh_token
    my $user_id = $user->{id};
    $oauth->revoke_refresh_tokens_by_user_id($user_id);
    BOM::User::AuditLog::log('Email has been changed', $user->{email});
}

=head2 save_user_dx_trading_password

This subroutine updates the DX trading password of a user. It first retrieves the user object using the user_id and correlation_id from the request. Then, it calls the 'update_dx_trading_password' method from the 'BOM::Service::User::Transitional::Password' module, passing the user object and the user's DX trading password.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The changes are saved directly to the user object.

=back

=cut

sub save_user_dx_trading_password {
    my ($request) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    BOM::Service::User::Transitional::Password::update_dx_trading_password($user, $user->{dx_trading_password});
}

=head2 save_user_trading_password

This subroutine updates the trading password of a user. It first retrieves the user object using the user_id and correlation_id from the request. Then, it calls the 'update_trading_password' method from the 'BOM::Service::User::Transitional::Password' module, passing the user object and the user's trading password.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The changes are saved directly to the user object.

=back

=cut

sub save_user_trading_password {
    my ($request) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    BOM::Service::User::Transitional::Password::update_trading_password($user, $user->{trading_password});
}

=head2 save_user_totp_fields

This subroutine updates the Time-based One-Time Password (TOTP) fields for a user. It first retrieves the user object using the user_id and correlation_id from the request. Then, it calls the 'update_totp_fields' method on the user object, passing the 'is_totp_enabled' and 'secret_key' attributes of the user.

Note: This function currently needs to pull in the functionality of 'BOM::User::update_totp_fields()'. There is a potential issue where 'update_totp_fields()' may not function as expected because user values have already been set.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The changes are saved directly to the user object.

=back

=cut

sub save_user_totp_fields {
    my ($request) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    BOM::Service::User::Transitional::TotpFields::update_totp_fields(
        $user,
        is_totp_enabled => $user->is_totp_enabled,
        secret_key      => $user->secret_key
    );
}

=head2 save_user_has_social_signup

This subroutine updates the social signup status of a user. It first retrieves the user object using the user_id and correlation_id from the request. Then, it calls the 'update_has_social_signup' method from the 'BOM::Service::User::Transitional::SocialSignup' module, passing the user object and the user's social signup status.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The changes are saved directly to the user object.

=back

=cut

sub save_user_has_social_signup {
    my ($request) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});

    BOM::Service::User::Transitional::SocialSignup::update_has_social_signup($user, $user->{has_social_signup});

    if (!$user->{has_social_signup}) {
        my $user_connect = BOM::Database::Model::UserConnect->new;
        my @providers    = $user_connect->get_connects_by_user_id($user->id);
        # remove all other social accounts
        $user_connect->remove_connect($user->id, $_) for @providers;
    }
}

=head2 save_user_password

This subroutine updates the password of a user. It first retrieves the user object using the user_id and correlation_id from the request. Then, it updates the user's password by running a database operation that calls the 'update_password' method from the 'users' table.

After updating the password, it sends out a message to confirm the password reset. The message includes the loginid, first name, email, and the reason for the password update.

Finally, it revokes all tokens associated with the user's loginids and refresh tokens associated with the user's id. It also logs the password update event.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The changes are saved directly to the user object and the user's tokens are revoked.

=back

=cut

sub save_user_password {
    my ($request) = @_;
    my $user      = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    my $reason    = $request->{flags}->{password_update_reason};
    my $log       = $reason eq 'reset_password' ? 'Password has been reset' : 'Password has been changed';

    $user->{password} = $user->dbic->run(
        fixup => sub {
            $_->selectrow_array('select * from users.update_password(?, ?)', undef, $user->id, $user->{password});
        });

    # Revoke all tokens
    my $oauth = BOM::Database::Model::OAuth->new;
    $oauth->revoke_refresh_tokens_by_user_id($user->id);
    $oauth->revoke_tokens_by_loginid($_) for ($user->bom_loginids);
    BOM::User::AuditLog::log($log, $user->email);
}

=head2 save_user_preferred_language

This subroutine updates the preferred language of a user. It first retrieves the user object using the user_id and correlation_id from the request. Then, it calls the 'update_preferred_language' method from the 'BOM::Service::User::Transitional::PreferredLanguage' module, passing the user object and the user's preferred language.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The changes are saved directly to the user object.

=back

=cut

sub save_user_preferred_language {
    my ($request) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});

    $user->{preferred_language} = $user->dbic->run(
        fixup => sub {
            $_->selectrow_array('select * from users.update_preferred_language(?, ?)', undef, $user->{id}, uc $user->{preferred_language});
        });
}

=head2 save_user_phone_number_verified

This subroutine updates the phone_number_verification setting of a user. It first retrieves the user object using the user_id and correlation_id from the request. Then, it calls the 'update_phone_number_verified' method, passing the user id and the user's phone verification setting.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The changes are saved directly to the user object.

=back

=cut

sub save_user_phone_number_verified {
    my ($request) = @_;
    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});

    $user->dbic(operation => 'write')->run(
        fixup => sub {
            $_->do('SELECT * FROM users.update_phone_number_verified(?::BIGINT, ?::BOOLEAN)',
                undef, $user->id, $user->{phone_number_verified} ? 1 : 0);
        });
}

=head2 save_user_feature_flags

This subroutine updates the feature_flags setting of a user. It first retrieves the user object using the user_id and correlation_id from the request. Then, it calls the 'set_feature_flag' method, passing the user id hash for features setting.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The changes are saved directly to the user db.

=back

=cut

sub save_user_feature_flags {
    my ($request)     = @_;
    my $user          = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    my $feature_flags = $request->{attributes}{feature_flag};

    foreach my $feature_name (keys $feature_flags->%*) {
        $user->dbic->run(
            fixup => sub {
                $_->do('SELECT users.set_feature_flag(?, ?, ?)', undef, $user->{id}, $feature_name, $feature_flags->{$feature_name});
            });
    }
}

=head2 _update_email_fields

Takes a user object and a hash or list of arguments. It updates the user's email, email consent, and email verification status in the database and returns the updated user object.

=over 4

=item * Input: User object, Hash or List (arguments)

=item * Return: Updated User object

=back

=cut

sub _update_email_fields {
    my ($user, %args) = @_;

    $args{email} = lc $args{email} if defined $args{email};
    my ($email, $email_consent, $email_verified) = $user->dbic->run(
        fixup => sub {
            $_->selectrow_array('select * from users.update_email_fields(?, ?, ?, ?)',
                undef, $user->{id}, $args{email}, $args{email_consent}, $args{email_verified});
        });
    $user->{email}          = $email          if (defined $args{email});
    $user->{email_consent}  = $email_consent  if (defined $args{email_consent});
    $user->{email_verified} = $email_verified if (defined $args{email_verified});
    return $user;
}

1;
