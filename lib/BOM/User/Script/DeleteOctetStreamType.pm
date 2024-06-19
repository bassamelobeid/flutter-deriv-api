package BOM::User::Script::DeleteOctetStreamType;

use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Platform::S3Client;

=head1 NAME

DeleteOctetStreamType

=cut

=head2 remove_client_authentication_docs_from_S3

Removes the client authentication documents from s3

=over 

=item * C<noisy> - boolean to print some info as the script goes on

=back

=cut

sub remove_client_authentication_docs_from_S3 {
    my $args        = shift // {};
    my $client_dbic = BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db->dbic;

    my $docs = $client_dbic->run(
        fixup => sub {
            $_->selectall_arrayref(<<'SQL', undef);
SELECT file_name, id
FROM betonmarkets.client_authentication_document
WHERE file_name like '%octet-stream%'
SQL
        });

    if ($docs) {
        my $s3_client = BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});
        foreach my $doc (@$docs) {
            my $filename = $doc->[0];
            my $id       = $doc->[1];
            $s3_client->delete($filename);
            printf('Deleting %s from S3 and Client Database', $filename) if $args->{noisy};
            $client_dbic->run(
                fixup => sub {
                    $_->do(<<'SQL', undef, $id);
DELETE 
FROM betonmarkets.client_authentication_document
WHERE id = ? 
SQL
                });
        }
    }

}

1;
