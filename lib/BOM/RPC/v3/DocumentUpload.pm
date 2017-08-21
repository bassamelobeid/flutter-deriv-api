package BOM::RPC::v3::DocumentUpload;

use strict;
use warnings;
use BOM::Platform::Context qw (localize);
use Try::Tiny;
use Date::Utility;

sub upload {
    my $params = shift;
    my ($client, $upload_id, $document_type, $document_id, $document_format, $expiration_date, $status, $file_name) =
        @{$params}{qw/client upload_id document_type document_id document_format expiration_date/};

    # Early return for virtual accounts.
    return BOM::RPC::v3::Utility::create_error({
            code              => 'UploadDenied',
            message_to_client => localize("Virtual accounts don't require document uploads.")}) if $client->is_virtual;

    if ($params->{status} && $params->{status} eq "success") {
        my ($doc) = $client->find_client_authentication_document(query => [document_path => $params->{file_name}]);
        $doc->{status} = "uploaded";
        $doc->save();

        return $params;
    }

    if ($expiration_date ne '') {
        my ($current_date, $parsed_date, $error);
        $current_date = Date::Utility->new();
        try {
            $parsed_date = Date::Utility->new($expiration_date);
        }
        catch {
            $error = $_;
        };
        if ($error) {
            # warn $error;
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'UploadDenied',
                    message_to_client => localize("Invalid expiration_date.")});
        } elsif ($parsed_date->is_before($current_date) || $parsed_date->is_same_as($current_date)) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'UploadDenied',
                    message_to_client => localize("expiration_date cannot be less than or equal to current date.")});
        }
    }

    if ($document_type && $document_id && $document_format && $expiration_date) {
        my $newfilename = join('.', $document_id, time(), $document_format);
        my $upload = {
            document_type              => $document_type,
            document_format            => $document_format,
            document_path              => $newfilename,
            authentication_method_code => 'ID_DOCUMENT',
            expiration_date            => $expiration_date,
            document_id                => $document_id,
            status                     => 'uploading',
        };
        $client->add_client_authentication_document($upload);
        $client->save();

        return {
            file_name => $newfilename,
            call_type => 1,
        };
    }

    return BOM::RPC::v3::Utility::create_error({
            code              => 'UploadDenied',
            message_to_client => localize("Missing parameter.")});
}

1;
