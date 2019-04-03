package BOM::RPC::v3::DocumentUpload;

use strict;
use warnings;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (localize);
use Date::Utility;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Event::Emitter;
use Syntax::Keyword::Try;
use feature 'state';
use base qw(Exporter);

use BOM::RPC::Registry '-dsl';

our @EXPORT_OK = qw(MAX_FILE_SIZE);

use constant MAX_FILE_SIZE => 8 * 2**20;

requires_auth();

rpc document_upload => sub {
    my $params = shift;
    my $args   = $params->{args};
    my $status = $args->{status};
    my $error  = validate_input($params);
    return create_upload_error($error) if $error;

    return start_document_upload($params) if $args->{document_type} and $args->{document_format};

    return successful_upload($params) if $status and $status eq 'success';

    return create_upload_error();
};

sub start_document_upload {
    my $params = shift;
    my $client = $params->{client};
    my $args   = $params->{args};
    unless ($client->get_db eq 'write') {
        $client->set_db('write');
    }

    my $upload_info;
    try {
        $upload_info = $client->db->dbic->run(
            ping => sub {
                $_->selectrow_hashref(
                    'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?)', undef,
                    $client->loginid,                                                           $args->{document_type},
                    $args->{document_format}, $args->{expiration_date} || undef,
                    $args->{document_id} || '', $args->{expected_checksum},
                    '', $args->{page_type} || '',
                );
            });
        return create_upload_error('duplicate_document') unless ($upload_info);
    }
    catch {
        warn 'Document upload db query failed.' . $_;
        return create_upload_error();
    };

    return {
        file_name => $upload_info->{file_name},
        file_id   => $upload_info->{file_id},
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

    try {
        my $finish_upload_result = $client->db->dbic->run(
            ping => sub {
                $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $args->{file_id});
            });
        return create_upload_error() unless $finish_upload_result and ($args->{file_id} == $finish_upload_result);
    }
    catch {
        warn 'Document upload db query failed.';
        return create_upload_error();
    };

    my $client_id = $client->loginid;

    my $status_changed;
    try {
        ($status_changed) = $client->db->dbic->run(
            ping => sub {
                $_->selectrow_array('SELECT * FROM betonmarkets.set_document_under_review(?)', undef, $client_id);
            });
    }
    catch {
        warn 'Unable to change client status in the db';
        return create_upload_error();
    };

    BOM::Platform::Event::Emitter::emit(
        'document_upload',
        {
            loginid => $client_id,
            file_id => $args->{file_id},
        });

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

    return validate_id_and_exp_date($args);
}

sub validate_id_and_exp_date {
    my $args          = shift;
    my $document_type = $args->{document_type};

    # The fields expiration_date and document_id are only required for certain
    #   document types, so only do this check in these cases.

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
    my $reason = shift;

    # This data is all static, so a state declaration stops reinitialization on every call to this function.
    state $default_error_code = 'UploadDenied';
    state $default_error_msg  = localize('Sorry, an error occurred while processing your request.');
    state $errors             = {
        virtual          => {message => localize("Virtual accounts don't require document uploads.")},
        already_expired  => {message => localize('Expiration date cannot be less than or equal to current date.')},
        missing_exp_date => {message => localize('Expiration date is required.')},
        missing_doc_id   => {message => localize('Document ID is required.')},
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

1;
