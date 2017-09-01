package BOM::RPC::v3::DocumentUpload;

use strict;
use warnings;
use BOM::Platform::Context qw (localize);
use Try::Tiny;
use Date::Utility;

sub upload {
    my $params = shift;
    my $client = $params->{client};
    my ($document_type, $document_id, $document_format, $expiration_date, $document_path, $status, $file_name) =
        @{$params->{args}}{qw/document_type document_id document_format expiration_date document_path status file_name/};

    # Early return for virtual accounts.
    return BOM::RPC::v3::Utility::create_error({
            code              => 'UploadDenied',
            message_to_client => localize("Virtual accounts don't require document uploads.")}) if $client->is_virtual;

    if (defined $expiration_date && $expiration_date ne '') {
        my ($current_date, $parsed_date, $error);
        $current_date = Date::Utility->new();
        try {
            $parsed_date = Date::Utility->new($expiration_date);
        }
        catch {
            $error = $_;
        };
        if ($error) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'UploadDenied',
                    message_to_client => localize("Invalid expiration_date.")});
        } elsif ($parsed_date->is_before($current_date) || $parsed_date->is_same_as($current_date)) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'UploadDenied',
                    message_to_client => localize("expiration_date cannot be less than or equal to current date.")});
        }
    } else {
        $expiration_date = '';
    }

    # Add new entry to database.
    if ($document_type && $document_format) {
        my $newfilename = join '.', $document_id, time(), $document_format;
        my $upload = {
            document_type              => $document_type,
            document_format            => $document_format,
            document_path              => '',
            authentication_method_code => 'ID_DOCUMENT',
            expiration_date            => $expiration_date,
            document_id                => $document_id || '',
            file_name                  => $newfilename,
            status                     => 'uploading',
        };
        $client->add_client_authentication_document($upload);
        $client->save();

        if (not $client->save()) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InternalServerError',
                    message_to_client => localize('Sorry, an error occurred while processing your request.')});
        }

        return {
            file_name => $newfilename,
            call_type => 1,
        };
    }

    # On success update the status of file to uploaded.
    if (defined $status && $status eq "success") {
        my ($doc) = $client->find_client_authentication_document(query => [file_name => $file_name]);

        # Return if document is not present in db.
        return BOM::RPC::v3::Utility::create_error({
                code              => 'UploadDenied',
                message_to_client => localize("Document not found.")}) unless defined($doc);

        $doc->{status}        = "uploaded";
        $doc->{document_path} = $document_path;

        if (not $doc->save()) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InternalServerError',
                    message_to_client => localize('Sorry, an error occurred while processing your request.')});
        }

        # Change client's account status.
        $client->set_status('under_review', 'system', 'Documents uploaded');
        if (not $client->save()) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InternalServerError',
                    message_to_client => localize('Sorry, an error occurred while processing your request.')});
        }

        return $params->{args};
    }

    return BOM::RPC::v3::Utility::create_error({
            code              => 'UploadDenied',
            message_to_client => localize("Missing parameter.")});
}

1;
