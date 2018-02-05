package BOM::RPC::v3::DocumentUpload;

use strict;
use warnings;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (localize);
use Date::Utility;
use BOM::Platform::Email qw(send_email);
use Try::Tiny;

use BOM::RPC::Registry '-dsl';

use constant MAX_FILE_SIZE => 3 * 2**20;

requires_auth();

rpc document_upload => sub {
    my $params = shift;
    my $args   = $params->{args};
    my $status = $args->{status};

    my $error = validate_input($params);
    return create_upload_error($error) if $error;

    return start_document_upload($params) if $args->{document_type} and $args->{document_format};

    return successful_upload($params) if $status and $status eq 'success';

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

    my $dbh;
    my $id;
    my $error_occured;
    try {
        my $STD_WARN_HANDLER = $SIG{__WARN__};
        local $SIG{__WARN__} = sub {
            return if _is_duplicate_upload_error($dbh);
            return $STD_WARN_HANDLER->(@_) if $STD_WARN_HANDLER;
            warn @_;
        };
        ($id) = $client->db->dbic->run(
            ping => sub {
                $dbh = $_;
                $dbh->selectrow_array(
                    'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?)',
                    undef, $loginid, $document_type, $document_format,
                    $args->{expiration_date},
                    ($args->{document_id} || ''),
                    $expected_checksum
                );
            });
    }
    catch {
        $error_occured = 1;
    };

    return create_upload_error('duplicate_document') if $error_occured and _is_duplicate_upload_error($dbh);

    if ($error_occured or not $id) {
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

    _set_staff($client);

    my $dbh;
    my $result;
    my $error_occured;
    try {
        my $STD_WARN_HANDLER = $SIG{__WARN__};
        local $SIG{__WARN__} = sub {
            return if _is_duplicate_upload_error($dbh);
            return $STD_WARN_HANDLER->(@_) if $STD_WARN_HANDLER;
            warn @_;
        };
        ($result) = $client->db->dbic->run(
            ping => sub {
                $dbh = $_;
                $dbh->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?, ?)', undef, $args->{file_id}, undef);
            });
    }
    catch {
        $error_occured = 1;
    };

    return create_upload_error('duplicate_document') if $error_occured and _is_duplicate_upload_error($dbh);

    return create_upload_error('doc_not_found') if not $result;

    if ($error_occured) {
        warn 'Failed to update the uploaded document in the db';
        return create_upload_error();
    }

    my $client_id = $client->loginid;

    my $status_changed;
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

    # Default values
    my $error_code = 'UploadDenied';
    my $message    = localize('Sorry, an error occurred while processing your request.');

    if ($reason eq 'virtual') {
        $message = localize("Virtual accounts don't require document uploads.");
    } elsif ($reason eq 'already_expired') {
        $message = localize('Expiration date cannot be less than or equal to current date.');
    } elsif ($reason eq 'missing_exp_date') {
        $message = localize('Expiration date is required.');
    } elsif ($reason eq 'missing_doc_id') {
        $message = localize('Document ID is required.');
    } elsif ($reason eq 'doc_not_found') {
        $message = localize('Document not found.');
    } elsif ($reason eq 'max_size') {
        $message = localize('Maximum file size reached. Maximum allowed is [_1]', MAX_FILE_SIZE);
    } elsif ($reason eq 'duplicate_document') {
        $error_code = 'DuplicateUpload';                        # Unique code for front-end handling
        $message    = localize('Document already uploaded.');
    } elsif ($reason eq 'checksum_mismatch') {
        $error_code = 'ChecksumMismatch';                       # Unique code for front-end handling
        $message    = localize('Checksum verification failed.');
    }

    return BOM::RPC::v3::Utility::create_error({
        code              => $error_code,
        message_to_client => $message
    });
}

sub _is_duplicate_upload_error {
    my $dbh = shift;

    return $dbh->state =~ /^23505$/
        and $dbh->errstr =~ /duplicate_upload_error/;
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
