package BOM::RPC::v3::DocumentUpload;

use strict;
use warnings;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (localize);
use BOM::Platform::Client::DocumentUpload;
use Date::Utility;
use BOM::Platform::Email qw(send_email);
use Try::Tiny;
use feature 'state';

use BOM::RPC::Registry '-dsl';

use constant MAX_FILE_SIZE => 3 * 2**20;

requires_auth();

rpc document_upload => sub {
    my $params = shift;
    my $args   = $params->{args};
    my $status = $args->{status};

    return successful_upload($params) if $status and $status eq 'success';

    my $error = validate_input($params);
    return create_upload_error($error) if $error;

    return start_document_upload($params) if $args->{document_type} and $args->{document_format};

    return create_upload_error();
};

sub start_document_upload {
    my $params  = shift;
    my $client  = $params->{client};
    my $args    = $params->{args};
    my $loginid = $client->loginid;
    my ($document_type, $document_format, $expected_checksum) =
        @{$args}{qw/document_type document_format expected_checksum/};

    unless ($client->get_db eq 'write') {
        $client->set_db('write');
    }

    _set_staff($client);

    my $query_result = BOM::Platform::Client::DocumentUpload::start_document_upload(
        $client, $loginid, $document_type, $document_format, $expected_checksum,
        $args->{expiration_date},
        ($args->{document_id} || ''));

    return create_upload_error('duplicate_document') if $query_result->{error} and $query_result->{error}->{dup};

    if ($query_result->{error} or not $query_result->{result}) {
        warn 'start_document_upload in the db was not successful';
        return create_upload_error();
    }

    return {
        file_name => join('.', $loginid, $document_type, $query_result->{result}, $document_format),
        file_id   => $query_result->{result},
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

    _set_staff($client);

    my $query_result = BOM::Platform::Client::DocumentUpload::finish_document_upload($client, $args->{file_id}, undef);

    return create_upload_error('duplicate_document') if $query_result->{error} and $query_result->{error}->{dup};

    return create_upload_error('doc_not_found') if not $query_result->{result};

    if ($query_result->{error}) {
        warn 'Failed to update the uploaded document in the db';
        return create_upload_error();
    }

    my $client_id = $client->loginid;

    my $status_changed;
    my $error_occured;
    try {
        ($status_changed) = $client->db->dbic->run(
            ping => sub {
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

    return $args unless $status_changed;

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

    return validate_doc_id_and_type($args);
}

sub validate_doc_id_and_type {
    my $args          = shift;
    my $document_type = $args->{document_type};
    my $document_id   = $args->{document_id};

    return if not $document_type or $document_type !~ /^passport|proofid|driverslicense$/;

    return 'missing_doc_id' if not $document_id;

    return;
}

sub validate_expiration_date {
    my $expiration_date = shift;

    return 'missing_exp_date' if not $expiration_date;

    my $current_date = Date::Utility->new;
    my $parsed_date  = Date::Utility->new($expiration_date);

    return 'already_expired' if not $parsed_date->is_after($current_date);

    return;
}

sub create_upload_error {
    my $reason = shift;

    # This data is all static, so a state declaration stops reinitialization on every call to this function.
    state $default_error_code = 'UploadDenied';
    state $default_error_msg  = localize('Sorry, an error occurred while processing your request.');
    state $errors             = {
        virtual          => {message => localize("Virtual accounts don't require document uploads.")},
        already_expired  => {message => localize('Expiration date cannot be less than or equal to current date.')},
        missing_exp_date => {message => localize('Expiration date is required.')},
        missing_doc_id   => {message => localize('Document ID is required.')},
        doc_not_found    => {message => localize('Document not found.')},
        max_size         => {message => localize("Maximum file size reached. Maximum allowed is [_1]", MAX_FILE_SIZE)},
        duplicate_document => {
            message    => localize('Document already uploaded.'),
            error_code => 'DuplicateUpload'
        },
        checksum_mismatch => {
            message    => localize('Checksum verification failed.'),
            error_code => 'ChecksumMismatch'
        },
    };

    my ($error_code, $message);
    ($error_code, $message) = ($errors->{$reason}->{error_code}, $errors->{$reason}->{message}) if $reason;

    return BOM::RPC::v3::Utility::create_error({
        code              => $error_code || $default_error_code,
        message_to_client => $message    || $default_error_msg
    });
}

sub _set_staff {
    my ($client) = @_;

    my $error_occured;
    try {
        $client->_set_staff;
    }
    catch {
        $error_occured = $_;
    };

    warn "Unable to set staff for saving the upload information, error: $error_occured" if $error_occured;

    return undef;
}

1;
