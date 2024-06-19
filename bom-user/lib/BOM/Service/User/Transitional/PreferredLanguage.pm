package BOM::Service::User::Transitional::PreferredLanguage;
use strict;
use warnings;

=head2 setnx_preferred_language

Set preferred language if not exists

=cut

sub setnx_preferred_language {
    my ($user, $lang_code) = @_;

    $user->update_preferred_language($lang_code) if !$user->{preferred_language};
}

=head2 update_preferred_language

Takes a user object and a language code. It updates the user's preferred language in the database and returns the updated preferred language. Note that there is a hidden database check on the field in the binary_user table.

=over 4

=item * Input: User object, String (lang_code)

=item * Return: String (updated preferred language)

=back

=cut

sub update_preferred_language {
    my ($user, $lang_code) = @_;

    # NOTE - There is a 'hidden' DB check on the field in the binary_user table
    # binary_user_preferred_language_check
    # preferred_language ~ '^[A-Z]{2}$|^[A-Z]{2}_[A-Z]{2}$'::text

    my $result = $user->dbic->run(
        fixup => sub {
            $_->selectrow_array('select * from users.update_preferred_language(?, ?)', undef, $user->{id}, uc $lang_code);
        });

    $user->{preferred_language} = $result if $result;

    return $user->{preferred_language};
}

1;
