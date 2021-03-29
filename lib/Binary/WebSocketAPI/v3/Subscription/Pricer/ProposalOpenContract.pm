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

        # forget if the contract is sold and we are not subscribed to all open contracts (CONTRACT_PRICE::<landing_company>::<account_id>::*).
        if ($message->{is_sold} && !($self->channel =~ m/\*/)) {
            $self->unregister;
        }

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

=head2 subscribe

subscribe the channel and store channel to Redis so that pricer_queue script can handle them

=cut

after subscribe => sub {
    my $self = shift;

    my $keys = $self->pricer_args;
    $keys = ref $keys eq 'ARRAY' ? $keys : [$keys];

    return unless scalar @$keys;

    my $redis_pricer_manager = Binary::WebSocketAPI::v3::SubscriptionManager->redis_pricer_manager();

    return $redis_pricer_manager->redis->mset(map { ($_, 1) } @$keys);
};

# DEMOLISH in subclass will prevent super ROLE's DEMOLISH in Subscription.pm. So here `before` is used.
before DEMOLISH => sub {
    my ($self, $global) = @_;
    return undef if $global;
    return undef unless $self->c;
    return undef;
};

1;
