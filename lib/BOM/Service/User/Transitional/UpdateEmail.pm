package BOM::Service::User::Transitional::UpdateEmail;
use strict;
use warnings;

=head2 update_email_fields

Takes a user object and a hash or list of arguments. It updates the user's email, email consent, and email verification status in the database and returns the updated user object.

=over 4

=item * Input: User object, Hash or List (arguments)

=item * Return: Updated User object

=back

=cut

sub update_email_fields {
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

=head2 update_email

Updates user and client emails for a given user.

=over 4

=item * C<new_email> - new email

=back

Returns 1 on success

=cut

sub update_email {
    my ($user, $new_email) = @_;

    $new_email = lc $new_email;
    update_email_fields($user, email => $new_email);
    my $oauth   = BOM::Database::Model::OAuth->new;
    my @clients = $user->clients(
        include_self_closed => 1,
        include_disabled    => 1,
        include_duplicated  => 1,
    );
    for my $client (@clients) {
        $client->email($new_email);
        $client->save;
        $oauth->revoke_tokens_by_loginid($client->loginid);
    }

    # revoke refresh_token
    my $user_id = $user->{id};
    $oauth->revoke_refresh_tokens_by_user_id($user_id);
    BOM::User::AuditLog::log('Email has been changed', $user->email);
    return 1;
}

1;
