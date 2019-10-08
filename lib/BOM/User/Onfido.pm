package BOM::User::Onfido;

=head1 Description

This file handles all the Onfido related codes

=cut

use strict;
use warnings;

use BOM::Database::UserDB;

sub get_user_onfido_applicant {
    my $user_id = shift;

    my $dbic           = BOM::Database::UserDB::rose_db()->dbic;
    my $applicant_data = $dbic->run(
        fixup => sub {
            my $sth = $_->selectrow_hashref('select * from users.get_onfido_applicant(?::BIGINT)', undef, $user_id);
        });

    return $applicant_data;
}

1;
