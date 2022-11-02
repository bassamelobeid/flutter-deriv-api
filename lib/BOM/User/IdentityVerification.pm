package BOM::User::IdentityVerification;

=head1 DESCRIPTION

Identity Verification services DB wrapper and utilities.

Note this module is meant to be decoupled from L<BOM::User> or L<BOM::User::Client>.

=cut

use strict;
use warnings;

use Date::Utility;
use JSON::MaybeUTF8 qw(:v2);
use Syntax::Keyword::Try;
use Log::Any qw($log);

use BOM::Platform::Context qw(request);
use BOM::Config::Redis;
use BOM::Database::UserDB;
use Moo;

use constant IDV_REQUEST_PER_USER_PREFIX    => 'IDV::REQUEST::PER::USER::';
use constant IDV_EXPIRED_CHANCE_USED_PREFIX => 'IDV::EXPIRED::CHANCE::USED::';
use constant ONE_WEEK                       => 604_800;

=head2 user_id

The current IDV user.

=cut

has user_id => (
    is       => 'ro',
    required => 1,
);

=head2 add_document

Add document row filled by provided info by user

=over 4

=item * C<$issuing_country> - the document issuing country

=item * C<$document_number> - the number of document, can be letters and numbers or combination of them

=item * C<$document_type> - the type of document

=item * C<$expiration_date> - nullable, the document expiry date

=back

Returns arrayref.

=cut

sub add_document {
    my ($self, $args) = @_;

    my ($issuing_country, $document_number, $document_type, $expiration_date) = @{$args}{
        qw/
            issuing_country   number            type            expiration_date
            /
    };

    die 'issuing_country is required' unless $issuing_country;
    die 'document_number is required' unless $document_number;
    die 'document_type is required'   unless $document_type;

    $expiration_date = Date::Utility->new($expiration_date)->date if $expiration_date;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM idv.add_document(?::BIGINT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TIMESTAMP)',
                    undef, $self->user_id, $issuing_country, $document_number, $document_type, $expiration_date);
            });
    } catch ($e) {
        die sprintf("Failed while adding document due to '%s'", $e);
    }

    return;
}

=head2 get_claimed_documents

Gets a list of documents with the same criteria but might uploaded by different users.

=over 4

=item * C<$issuing_country> - the document issuing country

=item * C<$document_number> - the number of document, can be letters and numbers or combination of them

=item * C<$document_type> - the type of document

=back

Returns arrayref or undef

=cut

sub get_claimed_documents {
    my ($self, $args) = @_;

    my ($issuing_country, $document_number, $document_type) = @{$args}{
        qw/
            issuing_country   number            type
            /
    };

    die 'issuing_country is required' unless $issuing_country;
    die 'document_number is required' unless $document_number;
    die 'document_type is required'   unless $document_type;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'SELECT * FROM idv.get_claimed_documents(?::TEXT, ?::TEXT, ?::TEXT)',
                    {Slice => {}},
                    $issuing_country, $document_type, $document_number
                );
            });
    } catch ($e) {
        die sprintf("Failed while getting claimed documents due to '%s'", $e);
    }

    return;
}

=head2 get_standby_document

Gets last standby document added by user

=cut

sub get_standby_document {
    my $self = shift;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM idv.get_standby_document(?::BIGINT)', undef, $self->user_id);
            });
    } catch ($e) {
        die sprintf("Failed while getting standby document for IDV process, check user_id: %s", $self->user_id);
    }

    return;
}

=head2 update_document_check

Updates status on idv.document and try to update
details in idv.document_check otherwise will
create new row for details.

=over 4

=item * C<$document_id> - the id of document to which this record belongs

=item * C<$status> - the status of check

=item * C<$message> - the message for status

=item * C<$provider> - the third-party provider which we use for IDV

=item * C<$report> - nullable,  a summary of provider response in unified structure

=item * C<$request_body> - nullable, the request body we sent to provider

=item * C<$response_body> - nullable, the response we received from provider

=item * C<$expiration_date> - nullable, the document expiry date

=back

Returns void.

=cut

sub update_document_check {
    my ($self, $args) = @_;

    my ($document_id, $status, $messages, $provider, $report, $request_body, $response_body, $expiration_date) = @{$args}{
        qw/
            document_id   status   messages   provider  report  request_body   response_body   expiration_date
            /
    };

    die 'document_id is required' unless $document_id;

    if (ref $messages eq 'ARRAY') {
        for my $msg ($messages->@*) {
            unless (defined $msg) {
                $log->warnf('IdentityVerification is pushing a NULL status message, document_id=%d, provider=%s', $document_id, $provider);
            }
        }
    }

    # should've already been utf8 decoded
    $messages        = encode_json_text($messages)                if $messages;
    $expiration_date = Date::Utility->new($expiration_date)->date if $expiration_date;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        $dbic->run(
            fixup => sub {
                $_->do(
                    'SELECT FROM idv.update_document_check(?::BIGINT, ?::idv.provider, ?::idv.check_status, ?::JSONB, ?::JSONB, ?::JSONB, ?::JSONB, ?::TIMESTAMP)',
                    undef, $document_id, $provider, $status, $messages, $report, $request_body, $response_body, $expiration_date
                );
            });
    } catch ($e) {
        die sprintf("Failed while updating document_check due to '%s', for document_id: %s", $e, $document_id);
    }

    return;
}

=head2 get_last_updated_document

Gets the document information which has been updated recently.

=cut

sub get_last_updated_document {
    my $self = shift;
    my $args = shift;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM idv.get_last_updated_document(?::BIGINT, ?::BOOL)',
                    undef, $self->user_id, $args->{only_verified} ? 1 : 0);
            });
    } catch ($e) {
        die sprintf("Failed while getting last IDV updated document, check user_id: %s", $self->user_id);
    }

    return;
}

=head2 get_document_check_detail

Gets the checks details for the given document information which has been updated recently.

=over 4

=item * C<$document_id> - the id of document

=back

=cut

sub get_document_check_detail {
    my ($self, $document_id) = @_;

    die 'ARGUMENT #1: document_id is required' unless $document_id;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM idv.get_document_check(?::BIGINT)', undef, $document_id);
            });
    } catch ($e) {
        die sprintf("Failed while getting document check detail, check user_id: %s", $self->user_id);
    }

    return;
}

=head2 get_rejected_reasons

Parses and extract the latest IDV rejection reasons for the current user.

Returns,
    an arrayref of possible reasons why the IDV attempt has been rejected

=cut

sub get_rejected_reasons {
    return [];    # TODO: proper implementation
}

=head2 submissions_left

Returns the submissions left for the user.

Returns,
    an integer representing the submissions left for the user involved.

=cut

sub submissions_left {
    my $self = shift;

    my $redis            = BOM::Config::Redis::redis_events();
    my $request_per_user = $redis->get(IDV_REQUEST_PER_USER_PREFIX . $self->user_id) // 0;
    my $submissions_left = limit_per_user() - $request_per_user;

    return $submissions_left;
}

=head2 has_expired_document_chance

Determines whether the expired doc chance has been used for this week.

=cut

sub has_expired_document_chance {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events_write();

    return !$redis->get(IDV_EXPIRED_CHANCE_USED_PREFIX . $self->user_id);
}

=head2 claim_expired_document_chance

Claims the expired document chance by writing the redis lock for one week.

=cut

sub claim_expired_document_chance {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events_write();

    return $redis->set(IDV_EXPIRED_CHANCE_USED_PREFIX . $self->user_id, 1, 'EX', ONE_WEEK);
}

=head2 expired_document_chance_ttl

Gets the TTL for the expired document chance reset.

=cut

sub expired_document_chance_ttl {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events();

    # will return -2 when the keys does not exists
    # will return -1 when the keys exists but no expiration was defined
    # otherwise will return the ttl in seconds.
    return $redis->ttl(IDV_EXPIRED_CHANCE_USED_PREFIX . $self->user_id);
}

=head2 incr_submissions

Increments the submissions for the user.

Returns,
    an integer representing the submissions left for the user involved.

=cut

sub incr_submissions {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events();
    my $left  = $self->submissions_left();

    # do not go beyond the limit
    return unless $left > 0;

    $redis->incr(IDV_REQUEST_PER_USER_PREFIX . $self->user_id);
}

=head2 reset_attempts

Get the attempts of the client back.

=cut

sub reset_attempts {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events();

    # Reset the expired docs chance
    $redis->del(IDV_EXPIRED_CHANCE_USED_PREFIX . $self->user_id);

    return $redis->del(IDV_REQUEST_PER_USER_PREFIX . $self->user_id);
}

=head2 decr_submissions

Decrements the submissions for the user.

Returns,
    an integer representing the submissions left for the user involved.

=cut

sub decr_submissions {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events();

    $redis->decr(IDV_REQUEST_PER_USER_PREFIX . $self->user_id);
}

=head2 reset_to_zero_left_submissions 

Reset left submissions count to zero equaivalent of disabling the IDV system.

=cut

sub reset_to_zero_left_submissions {
    my $user_id = shift;
    my $redis   = BOM::Config::Redis::redis_events();

    $redis->set(IDV_REQUEST_PER_USER_PREFIX . $user_id, limit_per_user());
}

=head2 limit_per_user

Provides a central point for onfido resubmissions limit per user in the specified
timeframe.

Returns,
    an integer representing the onfido submission requests allowed per user

=cut

sub limit_per_user {
    return $ENV{IDV_REQUEST_PER_USER_LIMIT} // 3;
}

=head2 reported_properties

Returns the user detected properties, from the latest IDV request, as a hashref.

It takes the following arguments:

Returns a hashref containing detected properties.

=cut

sub reported_properties {
    return {};    # TODO: proper implementation
}

=head2 status

Computes the current IDV status of the latest document uploaded 
or of the document which was passed to this sub as an argument

=over 4

=item C<$self> - Current class

=item C<$document> - Document to check it's status if provided

=back

Returns the mapped status. 

=cut

sub status {
    my ($self, $document) = @_;
    $document //= $self->get_last_updated_document();

    return 'none' unless $document;

    my $status_mapping = {
        refuted  => 'rejected',
        failed   => 'rejected',
        pending  => 'pending',
        verified => 'verified',
    };

    my $expiration_date;
    $expiration_date = Date::Utility->new($document->{document_expiration_date})->epoch if $document->{document_expiration_date};

    my $idv_status = $document->{status};
    my $status     = $status_mapping->{$idv_status} // 'none';
    $status = 'expired' if defined $expiration_date && time > $expiration_date;

    return $status;
}

=head2 get_document_check

Gets the the document check related to the given document.

=cut

sub get_document_check {
    my ($self, $document_id) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM idv.get_document_check(?::BIGINT)', undef, $document_id);
            });
    } catch ($e) {
        die sprintf("Failed while getting document check for IDV process, document_id: %s, error: %s", $document_id, $e);
    }

    return undef;
}

=head2 get_document_check_list

Gets the document check list in chronological descending order for the current user.

=cut

sub get_document_check_list {
    my $self = shift;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectall_arrayref('SELECT * FROM idv.get_document_check_list(?::BIGINT)', {Slice => {}}, $self->user_id);
            });
    } catch ($e) {
        die sprintf("Failed while getting the document chec list for IDV process, check user_id: %s, error: %s", $self->user_id, $e);
    }
}

=head2 get_document_list

Gets the document list in chronological descending order for the current user.

=cut

sub get_document_list {
    my $self = shift;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectall_arrayref('SELECT * FROM idv.get_document_list(?::BIGINT)', {Slice => {}}, $self->user_id);
            });
    } catch ($e) {
        die sprintf("Failed while getting the document list for IDV process, check user_id: %s, error: %s", $self->user_id, $e);
    }
}

=head2 is_idv_disallowed

Checks whether client allowed to verify identity via IDV based on some business rules

=over 4

=item * C<$client> - The corresponding client instance

=back

Returns bool

=cut

sub is_idv_disallowed {
    my $client = shift;

    # Only for non-regulated LC
    return 1 unless $client->landing_company->short eq 'svg';

    return 1 if $client->status->unwelcome;

    return 1 if ($client->aml_risk_classification // '') eq 'high';

    return 1 if $client->status->age_verification && $client->get_idv_status() ne 'expired';
    return 1 if $client->status->allow_poi_resubmission;

    if ($client->status->allow_document_upload) {
        my $manual_status = $client->get_manual_poi_status();
        return 1 if $manual_status eq 'expired' or $manual_status eq 'rejected';

        my $onfido_status = $client->get_onfido_status();
        return 1 if $onfido_status eq 'expired' or $onfido_status eq 'rejected';
    }

    return 0;
}

1;
