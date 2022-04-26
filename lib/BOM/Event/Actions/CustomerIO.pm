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
use Future::AsyncAwait;

=head2 user

the user instance

=cut

has user => (
    is       => 'ro',
    required => 1
);

=head2 _instance

Provides a wrapper instance for communicating with the Customerio web API.
It's a singleton - we don't want to leak memory by creating new ones for every event.

=cut

has _instance => (
    is      => 'ro',
    default => sub {
        my $loop = IO::Async::Loop->new;
        $loop->add(my $services = BOM::Event::Services->new);

        return $services->customerio;
    },
);

=head2 anonymize_user

Delete a user data from customer.io by C<user_id>

=cut

async sub anonymize_user {
    my $self = shift;

    try {
        my $customers = await $self->_instance->get_customers_by_email($self->user->email);

        for my $customer ($customers->@*) {
            await $customer->delete_customer();
        }
    } catch ($error) {
        $log->errorf("Customerio data deletion failed for user %s with failure reason %s", $self->user->id, $error);
        return $error;
    }

    return 1;
}

1;
