package BOM::RPC::v3::DocumentUpload;

use strict;
use warnings;
use Log::Any qw( $log );
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (localize);
use Date::Utility;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Event::Emitter;
use BOM::RPC::v3::Utility qw(log_exception);
use Syntax::Keyword::Try;
use feature 'state';
use base                       qw(Exporter);
use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::RPC::Registry '-dsl';

use List::MoreUtils qw(none any);

use BOM::User::Client;

our @EXPORT_OK = qw(MAX_FILE_SIZE);

use constant MAX_FILE_SIZE => 10 * 2**20;

use constant MAX_UPLOAD_TRIES_PER_DAY => 20;
use constant MAX_UPLOADS_TRIES_TTL    => 86400;                 # one day in second
use constant MAX_UPLOADS_KEY          => 'MAX_UPLOADS_KEY::';

requires_auth('trading', 'wallet');

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

    my %NEW_DOCUMENT_TYPE_MAPPING = (
        driverslicense => 'driving_licence',
        proofid        => 'national_identity_card',
        proofaddress   => 'utility_bill',
    );
    my $document_type = $NEW_DOCUMENT_TYPE_MAPPING{$args->{document_type}} // $args->{document_type};

    my $upload_info;
    try {
        my $expiration_date = $args->{expiration_date} || undef;
        my $lifetime_valid  = $args->{lifetime_valid} ? 1 : 0;
        my @poi_doctypes    = $client->documents->poi_types->@*;

        # lifetime only applies to favored POI types
        $lifetime_valid = 0 if none { $_ eq $document_type } @poi_doctypes;

        # If lifetime valid nullify the expiration date
        $expiration_date = undef if $lifetime_valid;

        $upload_info = $client->start_document_upload({
                document_type   => $document_type,
                document_format => $args->{document_format},
                document_id     => $args->{document_id} || '',
                expiration_date => $expiration_date,
                checksum        => $args->{expected_checksum} || '',
                page_type       => $args->{page_type}         || '',
                lifetime_valid  => $lifetime_valid,
                origin          => 'client',
                issuing_country => $args->{document_issuing_country}});

        return create_upload_error('duplicate_document') unless ($upload_info);

        # We can fulfill the proof of ownership with the file id
        if ($document_type eq 'proof_of_ownership') {
            my ($id, $details) = @{$args->{proof_of_ownership}}{qw/id details/};

            $client->proof_of_ownership->fulfill({
                id                                => $id,
                payment_method_details            => $details,
                client_authentication_document_id => $upload_info->{file_id},
            });
        }
    } catch ($error) {
        log_exception();
        $log->warnf('Document upload db query failed for %s:%s', $client->loginid, $error);
        return create_upload_error();
    }

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

    my $issuing_country = $args->{document_issuing_country};

    unless ($client->get_db eq 'write') {
        $client->set_db('write');
    }

    try {
        my $finish_upload_result = $client->finish_document_upload($args->{file_id});

        my $redis = BOM::Config::Redis::redis_replicated_write();
        my $key   = MAX_UPLOADS_KEY . $client->binary_user_id;

        $redis->set(
            $key,
            0,
            'EX' => MAX_UPLOADS_TRIES_TTL,
            'NX'
        );
        $redis->incrby($key, 1);
        DataDog::DogStatsd::Helper::stats_inc('bom_rpc.doc_upload_counter', {tags => ["loginid:" . $client->loginid]});

        # We set this status so CS agents can see documents where uploaded in sibling acc CR/MF
        $client->status->setnx('poi_poa_uploaded', 'system', 'Documents uploaded by ' . $client->broker_code);

        return create_upload_error() unless $finish_upload_result and ($args->{file_id} == $finish_upload_result);
    } catch ($error) {
        log_exception();
        $log->warnf('Document upload db query failed for %s:%s', $client->loginid, $error);
        return create_upload_error();
    }

    my $client_id = $client->loginid;

    try {
        # set client status as under_review if it is not already authenticated or under_review
        my $client_status = $client->authentication_status // '';

        if (!$client->fully_authenticated && $client_status ne 'under_review') {
            # Onfido unsupported countries can upload POI here as well, so narrow down it a bit
            my @poa_doctypes  = $client->documents->poa_types->@*;
            my ($doc)         = $client->find_client_authentication_document(query => [id => $params->{args}->{file_id}]);
            my $document_type = $doc->document_type;

            if (any { $_ eq $document_type } @poa_doctypes) {
                $client->set_authentication('ID_DOCUMENT', {status => 'under_review'});
            }
        }
    } catch ($error) {
        log_exception();
        $log->warnf('Unable to change client status in the db for %s:%s', $client->loginid, $error);
        return create_upload_error();
    }

    BOM::Platform::Event::Emitter::emit(
        'document_upload',
        {
            loginid         => $client_id,
            file_id         => $args->{file_id},
            issuing_country => $issuing_country,
        });

    BOM::Platform::Event::Emitter::emit(
        'sync_mt5_accounts_status',
        {
            binary_user_id => $client->binary_user_id,
            client_loginid => $client->loginid
        });

    return $args;
}

sub validate_input {
    my $params    = shift;
    my $args      = $params->{args};
    my $client    = $params->{client};
    my $file_size = $args->{file_size};
    my $status    = $args->{status};

    return 'max_upload_attempts_exceeded' unless $client->documents->is_upload_available;
    return 'max_size'      if $file_size and $file_size > MAX_FILE_SIZE;
    return $args->{reason} if $status    and $status eq 'failure';
    return 'virtual'       if $client->is_virtual;

    my $error = validate_expiration_date($args->{expiration_date}) // validate_id_and_exp_date({$args->%*, client => $client})
        // validate_proof_of_ownership({%$args{qw/proof_of_ownership document_type/}, %$params{qw/client/}})
        // validate_issuing_country({$args->%*, client => $client}) // validate_poa_status({$args->%*, client => $client})
        // validate_poi_status({$args->%*, client => $client});

    return $error;
}

=head2 validate_poi_status

Only applies to POI documents, it will return an error if the current POI status is pending and a complete bundle of POI documents
are uploaded.

It takes the following params as hashref:

=over 4

=item * - C<client> - the L<BOM::User::Client> instance

=item * - C<document_type> - a I<string> representing the document type being uploaded

=back

Returns a C<string> representing an error or I<undef> if there was no error found.

=cut

sub validate_poi_status {
    my ($args) = @_;
    my ($client, $document_type) = @{$args}{qw/client document_type/};

    return undef unless $document_type && any { $_ eq $args->{document_type} } $client->documents->poi_types->@*;

    return 'poi_pending' if $client->documents->pending_poi_bundle();

    return undef;
}

=head2 validate_poa_status

Only applies to POA documents, will return an error if the current POA status is pending.


It takes the following params as hashref:

=over 4

=item * - C<client> - the L<BOM::User::Client> instance

=item * - C<document_type> - a I<string> representing the document type being uploaded

=back

Returns a C<string> representing an error or I<undef> if there was no error found.

=cut

sub validate_poa_status {
    my ($args) = @_;
    my ($client, $document_type) = @{$args}{qw/client document_type/};

    return undef unless $document_type && any { $_ eq $args->{document_type} } $client->documents->poa_types->@*;

    return undef if $client->status->allow_poa_resubmission;

    return 'poa_pending' if $client->get_poa_status() eq 'pending';

    return undef;
}

=head2 validate_issuing_country

Only applies to POI documents.

It will check for a mandatory issuing country.

It takes the following params as hashref:

=over 4

=item * - C<client> - the L<BOM::User::Client> instance

=item * - C<document_issuing_country> - 2 letter country code

=item * - C<document_type> - a I<string> representing the document type being uploaded

=back

Returns a C<string> representing an error or I<undef> if there was no error found.

=cut

sub validate_issuing_country {
    my ($args) = @_;
    my ($client, $document_issuing_country, $document_type) = @{$args}{qw/client document_issuing_country document_type/};

    return undef unless $document_type && any { $_ eq $args->{document_type} } $client->documents->poi_types->@*;

    return 'missing_issuing_country' unless $document_issuing_country;

    return undef;
}

=head2 validate_proof_of_ownership

Only applies to proof_of_ownership document types, it will take special consideration
on the proof_of_ownership hashref given in the arguments.

It takes the following params as hashref:

=over 4

=item * - C<client> - the L<BOM::User::Client> instance

=item * - C<proof_of_ownership> - a hashref containing the I<id> of the POO being uploaded along with its I<details> 

=item * - C<document_type> - a I<string> representing the document type being uploaded

=back

Rules checked:

=over 4

=item * - The checks are ignored for every document type but I<proof_of_ownership>

=item * - The I<id> should exist and belong to the current client.

=item * - The I<details> hashref should exist.

=back

Returns a C<string> representing an error or I<undef> if there was no error found.

=cut

sub validate_proof_of_ownership {
    my ($args) = @_;
    my ($client, $proof_of_ownership, $document_type) = @{$args}{qw/client proof_of_ownership document_type/};

    return undef unless $document_type && $document_type eq 'proof_of_ownership';

    my ($id, $details) = @{$proof_of_ownership}{qw/id details/};

    return 'missing_proof_of_ownership_id' unless $id;

    my $list = $client->proof_of_ownership->list({
        id => $id,
    });

    return 'invalid_proof_of_ownership_id' unless $list && scalar @$list;

    return 'missing_proof_of_ownership_details' unless defined $details;

    return undef;
}

sub validate_id_and_exp_date {
    my $args          = shift;
    my $client        = $args->{client};
    my $document_type = $args->{document_type};

    return if not $document_type;
    return if $args->{lifetime_valid};

    # The fields expiration_date and document_id are only required for certain
    #   document types, so only do this check in these cases.
    return if none { $_ eq $document_type } $client->documents->expirable_types->@*;

    return 'missing_exp_date' if not $args->{expiration_date};
    return 'missing_doc_id'   if not $args->{document_id};

    return;
}

sub validate_expiration_date {
    my $expiration_date = shift;

    return if not $expiration_date;

    try {
        my $current_date = Date::Utility->new;
        my $parsed_date  = Date::Utility->new($expiration_date);

        return 'already_expired' unless $parsed_date->is_after($current_date);
    } catch {
        # Date Utility failed, so we cannot tell if the date is expired
        return 'invalid_exp_date';
    }

    return;
}

sub create_upload_error {
    my $reason = shift;

    # This data is all static, so a state declaration stops reinitialization on every call to this function.
    state $default_error_code = 'UploadDenied';
    state $default_error_msg  = localize('Sorry, an error occurred while processing your request.');
    state $errors             = {
        virtual                      => {message => localize("Virtual accounts don't require document uploads.")},
        invalid_exp_date             => {message => localize("Invalid expiration date")},
        already_expired              => {message => localize('Expiration date cannot be less than or equal to current date.')},
        missing_exp_date             => {message => localize('Expiration date is required.')},
        missing_doc_id               => {message => localize('Document ID is required.')},
        max_size                     => {message => localize("Maximum file size reached. Maximum allowed is [_1]", MAX_FILE_SIZE)},
        max_upload_attempts_exceeded =>
            {message => localize("Maximum upload attempts per day reached. Maximum allowed is [_1]", MAX_UPLOAD_TRIES_PER_DAY)},
        duplicate_document => {
            message    => localize('Document already uploaded.'),
            error_code => 'DuplicateUpload'
        },
        checksum_mismatch => {
            message    => localize('Checksum verification failed.'),
            error_code => 'ChecksumMismatch'
        },
        missing_proof_of_ownership_id      => {message => localize('You must specify the proof of ownership id')},
        invalid_proof_of_ownership_id      => {message => localize('The proof of ownership id provided is not valid')},
        missing_proof_of_ownership_details => {message => localize('You must specify the proof of ownership details')},
        missing_issuing_country            => {message => localize('Issuing country is mandatory for proof of identity')},
        poa_pending                        => {message => localize('POA document is already uploaded and pending for review')},
        poi_pending                        => {message => localize('POI documents are already uploaded and pending for review')}};

    my ($error_code, $message);
    ($error_code, $message) = ($errors->{$reason}->{error_code}, $errors->{$reason}->{message}) if $reason;

    return BOM::RPC::v3::Utility::create_error({
        code              => $error_code || $default_error_code,
        message_to_client => $message    || $default_error_msg
    });
}

1;
