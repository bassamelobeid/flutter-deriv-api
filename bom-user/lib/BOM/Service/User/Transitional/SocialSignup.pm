package BOM::Service::User::Transitional::SocialSignup;
use strict;
use warnings;

=head1 NAME

BOM::Service::User::Transitional::SocialSignup

=head1 DESCRIPTION

This package provides methods to update the social signup status for a user.

=head2 update_has_social_signup

Takes a user object and a boolean value indicating the social signup status. It updates the user's social signup status in the database and returns the updated user object.

=over 4

=item * Input: User object, Boolean (has_social_signup)

=item * Return: Updated User object

=back

=cut

sub update_has_social_signup {
    my ($user, $has_social_signup) = @_;
    $user->{has_social_signup} = $user->dbic->run(
        fixup => sub {
            $_->selectrow_array('select * from users.update_has_social_signup(?, ?)', undef, $user->{id}, $has_social_signup);
        });
    return $user;
}

1;
