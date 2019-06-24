package Binary::WebSocketAPI::v3::Subscription;

use strict;
use warnings;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription - The class that represent a subscription

=head1 DESCRIPTION

This module deals with the Redis interaction - it's an abstraction layer over the subscribe/publish/unsubscribe handling

=cut

no indirect;
use Moo;
use Try::Tiny;

use JSON::MaybeUTF8 qw(:v1);
use Log::Any qw($log);
use namespace::clean;

=head2 channel

The name of the channel we're subscribing to, as an ASCII string.

=cut

has channel => (
    is       => 'ro',
    required => 1,
);

=head2 manager

The SubscriptionManager instance that manage the subscription of this redis server.

=cut

has manager => (
    is       => 'ro',
    weak_ref => 1,
    required => 1,
);

=head2 worker

The SubscriptionRole subclass instance that do the real work

=cut

has worker => (
    is       => 'ro',
    weak_ref => 1,
    required => 1,
);

=head2 status

A L<Future> representing the subscription state - resolved if the subscription
is active.

    $subscription->status->is_done

=cut

has status => (
    is       => 'ro',
    required => 1,
);

=head1 METHODS

=cut

=head2 process

Handle incoming messages.

=cut

sub process {
    my ($self, $message) = @_;
    return try {
        my $data = decode_json_utf8($message);
        return $self->worker->handle_error($data->{error}{code}, $message) if exists $data->{error};
        return $self->worker->handle_message($data);
    }
    catch {
        if (defined($self->worker) ){
            $log->errorf("Failure processing Redis subscription message:  %s from original message %s, module %s, channel %s",
                $_, $message, $self->worker->class, $self->worker->channel);
        } else {
            $log->errorf("Failure processing Redis subscription message: %s from original message %s ",$_, $message);
        }
    }
}

1;

