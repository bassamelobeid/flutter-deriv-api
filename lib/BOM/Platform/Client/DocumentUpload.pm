package BOM::Platform::Client::DocumentUpload;

use strict;
use warnings;

use Try::Tiny;

sub start_document_upload {
    my (%args) = @_;
    return _do_query(
        $args{client},
        [
            'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?)',
            undef, $args{client}->loginid,
            $args{doctype}, $args{docformat},
            $args{expiration_date} || undef,
            $args{document_id}     || '',
            $args{file_checksum}]);
}

sub finish_document_upload {
    my (%args) = @_;
    return _do_query($args{client}, ['SELECT * FROM betonmarkets.finish_document_upload(?, ?)', undef, $args{file_id}, $args{comments}]);
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
    #   23505 is the PostgreSQL error code for a unique_violation.

    # Sample errstr (where "duplicate_upload_error" is the name of the unique index):
    #   ERROR:  duplicate key value violates unique constraint "duplicate_upload_error"
    #   DETAIL:  Key (client_loginid, checksum, document_type)=(CR10000, FileChecksum, passport) already exists.
    #
    # The regex here is matching on the set of columns that make up the key,
    #   rather than the name itself. This is because in future db maintenance
    #   the index could get rebuilt with a different name, but the columns are
    #   unlikely to change.
    #
    # Regex:
    # - Match literal parentheses at both ends
    # - Inside match either 'client_loginid', 'checksum', or 'document_type'
    #   - followed by either *nothing*, *comma*, or *comma space*
    #   - match this 3 times

    return $dbh->state eq '23505'
        && $dbh->errstr =~ /\(((client_loginid|checksum|document_type)(, ?)?){3}\)/;
}

1;
