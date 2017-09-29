package BOM::RPC::v3::DocumentUpload;

use strict;
use warnings;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (localize);
use Try::Tiny;
use Date::Utility;

use constant MAX_FILE_SIZE => 3 * 2**20;

sub upload {
    my $params = shift;
    my $client = $params->{client};
    my ($document_type, $document_id, $document_format, $expiration_date, $status, $file_id, $file_size, $reason) =
        @{$params->{args}}{qw/document_type document_id document_format expiration_date status file_id file_size reason/};

    return create_upload_error('UploadError', 'max_size') if $file_size and $file_size > MAX_FILE_SIZE;
    return create_upload_error('UploadError', $reason)    if $status    and $status eq 'failure';

    # Early return for virtual accounts.
    return create_upload_error('UploadDenied', localize("Virtual accounts don't require document uploads.")) if $client->is_virtual;

    if ($expiration_date) {
        my $current_date = Date::Utility->new;

        my ($parsed_date, $error);
        try {
            $parsed_date = Date::Utility->new($expiration_date);
        }
        catch {
            $error = $_;
        };

        if ($error) {
            return create_upload_error('UploadDenied', localize("Invalid expiration date."));
        } elsif ($parsed_date->is_before($current_date) || $parsed_date->is_same_as($current_date)) {
            return create_upload_error('UploadDenied', localize("Expiration date cannot be less than or equal to current date."));
        }
    } else {
        $expiration_date = undef;
    }

    # Check documentID and expiration date for passport, driverslicense, proofid
    if ($document_type and $document_type =~ /^passport|proofid|driverslicense$/) {
        return create_upload_error('UploadDenied', localize("Expiration date is required.")) unless $expiration_date;
        return create_upload_error('UploadDenied', localize("Document ID is required."))     unless $document_id;
    }

    my $loginid = $client->loginid;

    # Add new entry to database.
    if ($document_type && $document_format) {
        my $dbh = BOM::Database::ClientDB->new({broker_code => $client->broker_code})->db->dbh;

        my ($id) = $dbh->selectrow_array(
            "SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?, ?)",
            {Slice => {}},
            $loginid, $document_type, $document_format, '', $expiration_date, 'ID_DOCUMENT', $document_id || '',
            '', 'uploading'
        );

# ID should always be returned
        warn 'betonmarkets.start_document_upload should return the ID' if !$id;

        return create_upload_error('UploadError') if !$id;

        return {
            file_name => join('.', $loginid, $document_type, $id, $document_format),
            file_id   => $id,
            call_type => 1,
        };
    }

    # On success update the status of file to uploaded.
    if ($status and $status eq "success") {
        my ($doc) = $client->find_client_authentication_document(query => [id => $file_id]);

        # Return if document is not present in db.
        return create_upload_error('UploadDenied', localize("Document not found.")) unless $doc;

        $doc->{file_name} = join '.', $loginid, $doc->{document_type}, $doc->{id}, $doc->{document_format};
        $doc->{status} = "uploaded";

        if (not $doc->save()) {
            return create_upload_error('UploadError');
        }

        # Change client's account status.
        $client->set_status('under_review', 'system', 'Documents uploaded');
        if (not $client->save()) {
            return create_upload_error('UploadError');
        }

        return $params->{args};
    }

    return create_upload_error('UploadError');
}

sub create_upload_error {
    my ($code, $reason) = @_;

    my $message = $code eq 'UploadError' ? get_error_details($reason) : $reason;

    return BOM::RPC::v3::Utility::create_error({
        code              => $code,
        message_to_client => $message
    });
}

sub get_error_details {
    my $reason = shift || 'unkown';

    return localize('Maximum file size reached. Maximum allowed is [_1]', MAX_FILE_SIZE) if $reason eq 'max_size';
    return localize('Sorry, an error occurred while processing your request.');
}

1;
