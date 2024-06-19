package BOM::Service::User::Transitional::TotpFields;
use strict;
use warnings;

=head1 NAME

BOM::Service::User::Transitional::TotpFields

=head1 DESCRIPTION

This package provides methods to update the Time-based One-Time Password (TOTP) fields for a user.

=head2 update_totp_fields

Takes a user object and a hash or list of arguments. If 2FA is enabled, it won't update the secret key. It updates the user's TOTP fields in the database and revokes tokens if 2FA status is updated.

=over 4

=item * Input: User object, Hash or List (arguments)

=item * Return: Updated User object

=back

=cut

sub update_totp_fields {
    my ($user, %args) = @_;

    my $user_is_totp_enabled = $user->is_totp_enabled;

    # if 2FA is enabled, we won't update the secret key
    if ($args{secret_key} && $user_is_totp_enabled && ($args{is_totp_enabled} // 1)) {
        return;
    }

    my ($new_is_totp_enabled, $secret_key) = $user->dbic->run(
        fixup => sub {
            $_->selectrow_array('select * from users.update_totp_fields(?, ?, ?)', undef, $user->{id}, $args{is_totp_enabled}, $args{secret_key});
        });
    $user->{is_totp_enabled} = $new_is_totp_enabled;
    $user->{secret_key}      = $secret_key;

    # revoke tokens if 2FA is updated
    if ($user_is_totp_enabled xor $new_is_totp_enabled) {
        my $oauth = BOM::Database::Model::OAuth->new;
        $oauth->revoke_tokens_by_loignid_and_ua_fingerprint($_, $args{ua_fingerprint}) for ($user->bom_loginids);
        $oauth->revoke_refresh_tokens_by_user_id($user->id);
    }

    return $user;
}

1;
