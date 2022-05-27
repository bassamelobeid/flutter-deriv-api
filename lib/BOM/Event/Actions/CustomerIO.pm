package BOM::Event::Actions::CustomerIO;

use Moo;

use strict;
use warnings;

=head1 NAME

BOM::Event::Actions::CustomerIO - WebService::Async::CustomerIO Wrapper

=head1 SYNOPSIS

BOM::Event::Actions::CustomerIO->new(user => $user_instance);

=cut

use Log::Any qw( $log );
use Syntax::Keyword::Try;

use BOM::Event::Services;
use IO::Async::Loop;
use Future::AsyncAwait;

=head2 loop

IO::Async::Loop instance.

=cut

has loop => (
    is      => 'ro',
    default => sub { IO::Async::Loop->new },
);

=head2 _instance

Provides a wrapper instance for communicating with the Customerio web API.
It's a singleton - we don't want to leak memory by creating new ones for every event.

=cut

has _instance => (
    is      => 'lazy',
    default => sub {
        my $self = shift;
        $self->loop->add(my $services = BOM::Event::Services->new);
        return $services->customerio;
    },
);

=head2 anonymize_user

Delete a user data from customer.io by C<user> email.

=cut

async sub anonymize_user {
    my ($self, $user) = @_;

    try {
        my $customers = await $self->_instance->get_customers_by_email($user->email);

        for my $customer ($customers->@*) {
            await $customer->delete_customer();
        }
    } catch ($error) {
        $log->errorf("Customerio data deletion failed for user %s with failure reason %s", $user->id, $error);
        return $error;
    }

    return 1;
}

=head2 trigger_broadcast_by_ids

Triggers the campaign for C<campaign_id> with C<ids> of cio users.

=cut

async sub trigger_broadcast_by_ids {
    my ($self, $campaign_id, $ids, $data) = @_;

    # API has a limmit of 10k ids per request. Wrapper will handle rate limit.
    while (my @chunk = splice(@$ids, 0, 9999)) {
        try {
            await $self->loop->later;
            await $self->_instance->new_trigger(campaign_id => $campaign_id)->activate({
                ids => \@chunk,
                ($data // {})->%*
            });
        } catch ($e) {
            $log->errorf('Failed to trigger broadcast %s: %s', $campaign_id, $e);
        }
    }

    return 1;
}

1;
