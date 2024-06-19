package BOM::User::Script::IDVPhotoIdUpdater;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::User::Script::IDVPhotoIdUpdater - Update client authentication status to IDV Photo if required.

=head1 SYNOPSIS

    BOM::User::Script::IDVPhotoIdUpdater::run;

=head1 DESCRIPTION

This module is used by the `idv_photo_id_updater.pl` script. Meant to provide a testable
collection of subroutines.

Meant to be run once to bring authentication status to those who have obtained an IDV + Photo verification.

=cut

use BOM::Database::ClientDB;
use BOM::Database::UserDB;

=head2 run

Brings auth status idv + ID to those clients who had an IDV + PhotoID verification.

Retrieve idv checks with not null photo_id items.

Set the client as authenticate by IDV + PhotoID, unless a better auth method was already assinged.

IDV is a CR-only feature.

It takes a hashref argument:

=over

=item * C<noisy> - boolean to print some info as the script goes on

=back

Returns C<undef>

=cut

sub run {
    my $args    = shift // {};
    my $cr_dbic = BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db->dbic;

    my $user_db = BOM::Database::UserDB::rose_db()->dbic;

    # we will move around in a paginated fashion
    my $limit   = 100;
    my $offset  = 0;
    my $counter = 0;
    my $checks  = [];

    do {
        printf("Retrieving idv.document_check with offset = %d\n", $offset) if $args->{noisy};

        # grabbing all idv users with photo id, note there was a bug where in some cases the photo_id column
        # gets a [NULL] value instead of empty array.
        $checks = $user_db->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'select photo_id[1] AS photo_id from idv.document_check chk inner join idv.document doc on doc.id=chk.document_id where photo_id is not null AND array_length(ARRAY_REMOVE(photo_id, null), 1) > 0 limit ? offset ?',
                    {Slice => {}}, $limit, $offset
                );
            });

        # due to a bug some client have a client authentication document with octet stream type which is not valid
        my $doc_ids = [map { $_->{photo_id} } $checks->@*];

        my $docs = $cr_dbic->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'select distinct cli.binary_user_id from betonmarkets.client_authentication_document cad inner join betonmarkets.client cli on cli.loginid=cad.client_loginid where id = ANY(?) and document_format != \'octet-stream\'',
                    {Slice => {}},
                    $doc_ids
                );
            });

        # these are the binary user ids with photo id
        my $binary_user_ids = [map { $_->{binary_user_id} } $docs->@*];

        # add auth method IDV_PHOTO only if no other auth method is present
        $cr_dbic->run(
            fixup => sub {
                $_->do(
                    "INSERT INTO betonmarkets.client_authentication_method (client_loginid, authentication_method_code, status) SELECT cli.loginid, 'IDV_PHOTO', 'pass' FROM betonmarkets.client cli LEFT JOIN betonmarkets.client_authentication_method cam ON cam.client_loginid=cli.loginid WHERE cam.id IS NULL AND cli.binary_user_id = ANY(?) ON CONFLICT ON CONSTRAINT uk_client_authentication_method DO NOTHING",
                    undef, $binary_user_ids
                );
            });

        $offset  += $limit;
        $counter += scalar @$checks;
    } while (scalar @$checks);

    printf("Finished = %d clients found with IDV Photo ID\n", $counter) if $args->{noisy};

}

1;
