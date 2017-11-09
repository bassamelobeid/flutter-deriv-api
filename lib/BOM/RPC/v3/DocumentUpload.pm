package BOM::RPC::v3::DocumentUpload;

use strict;
use warnings;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (localize);
use Date::Utility;
use BOM::Platform::Email qw(send_email);
use Try::Tiny;

use constant MAX_FILE_SIZE => 3 * 2**20;

sub upload {
    my $params = shift;
    my $args   = $params->{args};
    my $status = $args->{status};

    my $error = validate_input($params);
    return create_upload_error($error) if $error;

    return start_document_upload($params) if $args->{document_type} and $args->{document_format};

    return successful_upload($params) if $status and $status eq 'success';

    return create_upload_error();
}

sub start_document_upload {
    my $params          = shift;
    my $client          = $params->{client};
    my $args            = $params->{args};
    my $document_type   = $args->{document_type};
    my $document_format = $args->{document_format};
    my $loginid         = $client->loginid;

    my $id;
    my $error_occured;
    try {
        ($id) = $client->db->dbic->run(
            fixup => sub {
                $_->selectrow_array(
                    'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?, ?::status_type)',
                    undef, $loginid, $document_type, $document_format, '', $args->{expiration_date},
                    'ID_DOCUMENT', ($args->{document_id} || ''),
                    '', 'uploading'
                );
            });
    }
    catch {
        $error_occured = 1;
    };

    if ($error_occured or !$id) {
        warn 'start_document_upload in the db was not successful';
        return create_upload_error();
    }

    return {
        file_name => join('.', $loginid, $document_type, $id, $document_format),
        file_id   => $id,
        call_type => 1,
    };
}

sub successful_upload {
    my $params = shift;
    my $client = $params->{client};
    my $args   = $params->{args};

    unless ($client->get_db eq 'write') {
        $client->set_db('write');
    }

    my $result;
    my $error_occured;
    try {
        $result = $client->db->dbic->run(
            fixup => sub {
                $_->do(
                    "UPDATE betonmarkets.client_authentication_document AS doc_table set checksum = ?, status = 'uploaded', file_name = doc_table.client_loginid || '.' || doc_table.document_type || '.' || doc_table.id || '.' || doc_table.document_format where doc_table.id = ?",
                    undef, $args->{checksum}, $args->{file_id});
            });
    }
    catch {
        $error_occured = 1;
    };

    if ($error_occured or !$result) {
        warn 'Failed to update the uploaded document in the db';
        return create_upload_error();
    }

    my $client_id = $client->loginid;

    my $changed_status;
    try {
        $changed_status = $client->db->dbic->run(
            fixup => sub {
                $_->selectrow_array('SELECT * FROM betonmarkets.set_document_under_review(?,?)', undef, $client_id, 'Documents uploaded');
            });
    }
    catch {
        $error_occured = 1;
    };

    if ($error_occured) {
        warn 'Unable to change client status in the db';
        return create_upload_error();
    }

    return $args unless $changed_status;

    my $email_body = "New document was uploaded for the account: " . $client_id;

    send_email({
        'from'                  => 'no-reply@binary.com',
        'to'                    => 'authentications@binary.com',
        'subject'               => 'New uploaded document for: ' . $client_id,
        'message'               => [$email_body],
        'use_email_template'    => 0,
        'email_content_is_html' => 0
    });

    return $args;
}

sub validate_input {
    my $params    = shift;
    my $args      = $params->{args};
    my $client    = $params->{client};
    my $file_size = $args->{file_size};
    my $status    = $args->{status};

    return 'max_size'      if $file_size and $file_size > MAX_FILE_SIZE;
    return $args->{reason} if $status    and $status eq 'failure';
    return 'virtual'       if $client->is_virtual;

    my $invalid_date = validate_expiration_date($args->{expiration_date});
    return $invalid_date if $invalid_date;

    return validate_id_and_exp_date($args);
}

sub validate_id_and_exp_date {
    my $args          = shift;
    my $document_type = $args->{document_type};

    return if not $document_type or $document_type !~ /^passport|proofid|driverslicense$/;

    return 'missing_exp_date' if not $args->{expiration_date};
    return 'missing_doc_id'   if not $args->{document_id};

    return;
}

sub validate_expiration_date {
    my $expiration_date = shift;

    return if not $expiration_date;

    my $current_date = Date::Utility->new;
    my $parsed_date  = Date::Utility->new($expiration_date);

    return 'already_expired' if not $parsed_date->is_after($current_date);

    return;
}

sub create_upload_error {
    my $reason = shift || 'unkown';

    my $message;
    if ($reason eq 'virtual') {
        $message = localize("Virtual accounts don't require document uploads.");
    } elsif ($reason eq 'already_expired') {
        $message = localize('Expiration date cannot be less than or equal to current date.');
    } elsif ($reason eq 'missing_exp_date') {
        $message = localize('Expiration date is required.');
    } elsif ($reason eq 'missing_doc_id') {
        $message = localize('Document ID is required.');
    } elsif ($reason eq 'max_size') {
        $message = localize('Maximum file size reached. Maximum allowed is [_1]', MAX_FILE_SIZE);
    } else {    # Default
        $message = localize('Sorry, an error occurred while processing your request.');
    }

    return BOM::RPC::v3::Utility::create_error({
        code              => 'UploadDenied',
        message_to_client => $message
    });
}

1;
