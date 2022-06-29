package BOM::User::IdentityVerification;

=head1 DESCRIPTION

Identity Verification services DB wrapper and utilities.

Note this module is meant to be decoupled from L<BOM::User> or L<BOM::User::Client>.

=cut

use strict;
use warnings;

use Date::Utility;
use JSON::MaybeUTF8 qw( encode_json_utf8 );
use Syntax::Keyword::Try;
use Log::Any qw($log);

use BOM::Config::Redis;
use BOM::Database::UserDB;

use Moo;

use constant IDV_REQUEST_PER_USER_PREFIX => 'IDV::REQUEST::PER::USER::';

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

=item * C<$issuing_country> - the id of document to which this record belongs

=item * C<$document_number> - the status of check

=item * C<$document_type> - the message for status

=item * C<$expiration_date> - nullable, the document expiry date

=back

Returns void.

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

=item * C<$request_body> - nullable, the request body we sent to provider

=item * C<$response_body> - nullable, the response we received from provider

=item * C<$expiration_date> - nullable, the document expiry date

=back

Returns void.

=cut

sub update_document_check {
    my ($self, $args) = @_;

    my ($document_id, $status, $messages, $provider, $request_body, $response_body, $expiration_date) = @{$args}{
        qw/
            document_id   status   messages   provider   request_body   response_body   expiration_date
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

    $messages        = encode_json_utf8($messages)                if $messages;
    $expiration_date = Date::Utility->new($expiration_date)->date if $expiration_date;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        $dbic->run(
            fixup => sub {
                $_->do(
                    'SELECT FROM idv.update_document_check(?::BIGINT, ?::idv.provider, ?::idv.check_status, ?::JSONB, ?::JSONB, ?::JSONB, ?::TIMESTAMP)',
                    undef, $document_id, $provider, $status, $messages, $request_body, $response_body, $expiration_date
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

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM idv.get_last_updated_document(?::BIGINT)', undef, $self->user_id);
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

=head2 incr_submissions

Returns the submissions left for the user.

Returns,
    an integer representing the submissions left for the user involved.

=cut

sub incr_submissions {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events();

    $redis->incr(IDV_REQUEST_PER_USER_PREFIX . $self->user_id);
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
    return $ENV{IDV_REQUEST_PER_USER_LIMIT} // 2;
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

Computes the current IDV status, to avoid API inconsistency we should map whatever
status we are storing in the database to: none, expired, pending, rejected, suspected, verified.

Returns the mapped status. 

=cut

sub status {
    return 'none';    # TODO: proper implementation
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

1;
