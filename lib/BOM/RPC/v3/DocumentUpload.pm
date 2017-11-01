package BOM::RPC::v3::DocumentUpload;

use strict;
use warnings;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (localize);
use Date::Utility;
use BOM::Platform::Email qw(send_email);

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

    my $dbh = BOM::Database::ClientDB->new({broker_code => $client->broker_code})->db->dbh;
    my $loginid = $client->loginid;

    my ($id) = $dbh->selectrow_array(
        'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?, ?::status_type)',
        undef, $loginid, $document_type, $document_format, '', $args->{expiration_date},
        'ID_DOCUMENT', ($args->{document_id} || ''),
        '', 'uploading'
    );

# ID should always be returned by above call
    if (!$id) {
        warn 'betonmarkets.start_document_upload should return the ID';
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

    my ($doc) = $client->find_client_authentication_document(query => [id => $args->{file_id}]);

    return create_upload_error('doc_not_found') if not $doc;

    $doc->{file_name} = join '.', $client->loginid, $doc->{document_type}, $doc->{id}, $doc->{document_format};
    $doc->{checksum}  = $args->{checksum};
    $doc->{status}    = 'uploaded';

    if (not $doc->save()) {
        warn 'Unable to save upload information in the db';
        return create_upload_error();
    }

    return $args if $client->get_status('document_under_review');

# Change client's account status.
    $client->set_status('document_under_review', 'system', 'Documents uploaded');
    $client->clr_status('document_needs_action');

    if (not $client->save()) {
        warn 'Unable to change client status';
        return create_upload_error();
    }

    my $email_body = "New document was uploaded for the account: " . $client->loginid;

    send_email({
        'from'                  => 'no-reply@binary.com',
        'to'                    => 'authentications@binary.com',
        'subject'               => 'New uploaded document',
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
    } elsif ($reason eq 'doc_not_found') {
        $message = localize('Document not found.');
    } elsif ($reason eq 'doc_not_found') {
        $message = localize('Document not found.');
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
