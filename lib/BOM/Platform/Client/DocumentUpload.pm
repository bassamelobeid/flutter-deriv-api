package BOM::Platform::Client::DocumentUpload;

use strict;
use warnings;

use Try::Tiny;

sub start_document_upload {
    my ($client, $loginid, $doctype, $docformat, $file_checksum, $expiration_date, $document_id) = @_;
    return _do_query(
        $client,
        [
            'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?)',
            undef, $loginid, $doctype, $docformat,
            $expiration_date || undef,
            $document_id     || '',
            $file_checksum
        ]);
}

sub finish_document_upload {
    my ($client, $file_id, $comments) = @_;
    return _do_query($client, ['SELECT * FROM betonmarkets.finish_document_upload(?, ?)', undef, $file_id, $comments]);
}

sub _do_query {
    my ($client, $cmd_and_args) = @_;
    my ($query_result, $error_occured, $error_duplicate);
    try {
        ($query_result) = $client->db->dbic->run(
            ping => sub {
                my $STD_WARN_HANDLER = $SIG{__WARN__};
                local $SIG{__WARN__} = sub {
                    # We want to suppress duplicate upload attempts from being logged as errors
                    return if $error_duplicate = _is_duplicate_upload_error($_);
                    # Just in case there is already a custom warning handler,
                    #   we don't disrupt the usual flow.
                    # At the time of writing, the test environment applies a custom handler,
                    #   the production environment does not.
                    return $STD_WARN_HANDLER->(@_) if $STD_WARN_HANDLER;
                    warn @_;
                };
                $_->selectrow_array(@$cmd_and_args);
            });
    }
    catch {
        $error_occured = $_;
    };
    return _create_error($error_occured, $error_duplicate) if $error_occured;
    return _create_success($query_result);
}

sub _create_success {
    my ($result) = @_;

    return {result => $result};
}

sub _create_error {
    my ($msg, $duplicate_error) = @_;

    return {
        error => {
            msg => $msg,
            dup => $duplicate_error
        }};
    # Include a flag for the case of duplicate error because this 'error' is
    #   expected during normal operation, and the calling code will likely need
    #   to handle it differently.
}

sub _is_duplicate_upload_error {
    my $dbh = shift;

    # Duplicate uploads are detected using a unique index on the document table.
    #   23505 is the PSQL error code for a unique_violation.
    #   'duplicate_upload_error' is the specific name of the unique index.

    return $dbh->state eq '23505'
        and $dbh->errstr =~ /duplicate_upload_error/;
}

1;
