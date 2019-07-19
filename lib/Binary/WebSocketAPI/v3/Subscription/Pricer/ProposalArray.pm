package Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalArray;
use strict;
use warnings;
no indirect;

use Moo;
with 'Binary::WebSocketAPI::v3::Subscription::Pricer';
use namespace::clean;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalArray - The class that
handle proposal array channels 

=head1 DESCRIPTION

This module is the interface for pricer proposal array subscription-related tasks
Please refer to L<Binary::WebSocketAPI::v3::Subscription>

This type of subscription will never do subscribing. It is only used for storing information.

=cut

=head1 ATTRIBUTES

=head2 req_args

When create the object, the attribute args will not same with the original
request args. So we should create a new attribute req_args to store that. It
will be used by
L<Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalArrayItem> 


=cut

has req_args => (
    is      => 'rw',
    default => sub { +{} },
);

=head2 proposals

Store proposals data that are generated by L<Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalArrayItem/_handle_message>, and will be processed by collector.

=cut

has proposals => (
    is      => 'rw',
    default => sub { +{} },
);

=head2 seq

Store UUID so that build the relationship between args->{barriers} and proposals. Please refer to
L<Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalArrayItem>

=cut

has seq => (
    is      => 'rw',
    default => sub { [] },
);

=head1 METHODS

=cut

sub subscribe {
    die "Proposal Array type should not do real subscribing";
}

sub do_handle_message {
    die "Proposal Array type should not handle message";
}

# DEMOLISH in subclass will prevent super ROLE's DEMOLISH in Subscription.pm. So here `before` is used.
before DEMOLISH => sub {
    my ($self, $global) = @_;
    return undef if $global;
    return undef unless $self->c;
    for my $item_uuid (@{$self->seq}) {
        $self->get_by_uuid($self->c, $item_uuid)->unregister;
    }
    return undef;
};

1;
