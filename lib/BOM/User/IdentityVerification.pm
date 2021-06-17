package BOM::User::IdentityVerification;

=head1 DESCRIPTION

Identity Verification services DB wrapper and utilities.

Note this module is meant to be decoupled from L<BOM::User> or L<BOM::User::Client>.

=cut

use strict;
use warnings;

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

1;
