package BOM::User::IdentityVerification;

=head1 DESCRIPTION

Identity Verification services DB wrapper and utilities.

Note this module is meant to be decoupled from L<BOM::User> or L<BOM::User::Client>.

=cut

use strict;
use warnings;

use Syntax::Keyword::Try;

use BOM::Config::Redis;
use Moo;

use constant IDV_REQUEST_PER_USER_PREFIX => 'IDV::REQUEST::PER::USER::';

=head2 user_id

The current IDV user.

=cut

has 'user_id' => (
    is       => 'ro',
    required => 1,
);

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
    my $self             = shift;
    my $redis            = BOM::Config::Redis::redis_events();
    my $request_per_user = $redis->get(IDV_REQUEST_PER_USER_PREFIX . $self->user_id) // 0;
    my $submissions_left = $self->limit_per_user() - $request_per_user;
    return $submissions_left;
}

=head2 limit_per_user

Provides a central point for onfido resubmissions limit per user in the specified
timeframe.

Returns,
    an integer representing the onfido submission requests allowed per user

=cut

sub limit_per_user {
    return $ENV{IDV_REQUEST_PER_USER_LIMIT} // 0;    # TODO: proper implementation
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

=head2 get_last_updated_document

Gets the latest document added by user

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
        die sprintf("Failed while getting last updated document for IDV process, check user_id: %s, error: %s", $self->user_id, $e);
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

    return undef;
}

1;
