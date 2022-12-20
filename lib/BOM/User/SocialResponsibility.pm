package BOM::User::SocialResponsibility;

=head1 Description

This file handles all the social responsibility related codes

=cut

use strict;
use warnings;

use BOM::Database::UserDB;

=head2 dbic

Gets a connection to user database.

=cut

sub dbic {
    return BOM::Database::UserDB::rose_db()->dbic;
}

=head2 update_sr_risk_status

Calls a db function to store a sr_risk_status for the user.

=over 4

=item * C<sr_risk_status> - new sr_risk_status

=back

Returns $self

=cut

sub update_sr_risk_status {
    my ($self, $binary_id, $sr_risk_status) = @_;

    die 'socialResponsibilityRequired' unless $sr_risk_status;

    die 'invalidSocialResponsibilityType' unless $sr_risk_status =~ qr/low|high|manual override high|problem trader/;

    my $status = dbic->run(
        fixup => sub {
            $_->selectrow_array('select sr_risk_status from users.update_sr_risk_status(?, ?)', undef, $binary_id, $sr_risk_status);
        });

    return $status;
}

=head2 get_sr_risk_status

Calls a db function to get a sr_risk_status for the user.

=over 4

=item * C<binary_user_id> -  binary_user_id

=back

Returns $self

=cut

sub get_sr_risk_status {
    my ($self, $binary_id) = @_;

    my ($sr_risk_status) = dbic->run(
        fixup => sub {
            $_->selectrow_array('select sr_risk_status from users.get_sr_risk_status_by_id(?)', undef, $binary_id);
        });

    return $sr_risk_status;
}

1;
