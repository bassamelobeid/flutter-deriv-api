package Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalOpenContract;
use strict;
use warnings;
no indirect;

use Format::Util::Numbers qw/formatnumber roundcommon/;
use Binary::WebSocketAPI::v3::Subscription::Transaction;
use Moo;
with 'Binary::WebSocketAPI::v3::Subscription::Pricer';
use namespace::clean;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalOpenContract - The class that handle proposal open contract channels

=head1 DESCRIPTION

This module is the interface for pricer proposal open contract subscription-related tasks
Please refer to L<Binary::WebSocketAPI::v3::Subscription>

=cut

sub do_handle_message {
    my ($self, $message) = @_;
    my $c    = $self->c;
    my $type = 'proposal_open_contract';
    my $results;
    unless ($results = $self->_is_response_or_self_invalid($type, $message)) {
        $message->{id} = $self->uuid;

        $self->unregister if $message->{is_sold};

        $results = {
            msg_type     => $type,
            $type        => $message,
            subscription => {id => $self->uuid},
        };
    }
    if ($c->stash('debug')) {
        $results->{debug} = {
            time   => $results->{$type}->{rpc_time},
            method => $type,
        };
    }
    delete $results->{$type}->{rpc_time};
    # creating full response message here.
    # to use hooks for adding debug or other info it will be needed to fully re-create 'req_storage' and
    # pass it as a second argument for 'send'.
    # not storing req_storage in channel cache because it contains validation code
    # same is for process_ask_event.
    $results->{$type}->{validation_error} = $c->l($results->{$type}->{validation_error}) if ($results->{$type}->{validation_error});

    $c->send({json => $results}, {args => $self->args});

    return;
}

# DEMOLISH in subclass will prevent super ROLE's DEMOLISH in Subscription.pm. So here `before` is used.
before DEMOLISH => sub {
    my ($self, $global) = @_;
    return undef if $global;
    return undef unless $self->c;
    return undef;
};

1;
