package Binary::WebSocketAPI::v3::Subscription::Pricer;

use strict;
use warnings;
no indirect;
use feature qw(state);

use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Wrapper::Pricer;
use JSON::MaybeUTF8 qw(:v1);
use Log::Any qw($log);
use List::Util qw(min);
use Moo::Role;
use Format::Util::Numbers qw/financialrounding/;
with 'Binary::WebSocketAPI::v3::Subscription';

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::Pricer - base class for pricer subscriptions

=head1 DESCRIPTION

This module is the common interface for pricer subscription-related tasks
Please refer to L<Binary::WebSocketAPI::v3::Subscription>

=cut

=head1 ATTRIBUTES

=head2 cache

a hash that be used to cache something, like  contract_parameters in Proposal

=cut

has cache => (
    is       => 'ro',
    required => 1,
);

has '+channel' => (
    is       => 'ro',
    required => 1
);

=head2 subchannel

=cut

has subchannel => (
    is       => 'ro',
    required => 1,
);

has pricer_args => (
    is       => 'ro',
    required => 1,
);

=head1 METHODS

=head2 subscription_manager

The SubscriptionManager instance that will manage this worker

=cut

sub subscription_manager {
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_pricer_subscription_manager();
}

# This method is used to find a subscription. Class name + _unique_key will be a unique index of the subscription objects.
sub _unique_key {
    my $self = shift;
    return join '###', $self->channel, $self->subchannel;
}

=head2 handle_error

handle error.

=cut

sub handle_error {
    my ($self, undef, undef, $data) = @_;
    # In Pricer we needn't process error, we just give it back to client
    return $data;
}

=head2 handle_message

=cut

sub handle_message {
    my ($self, $message) = @_;

    my $c = $self->c;
    unless ($c->tx) {
        for my $subclass (qw(Proposal ProposalOpenContract)) {
            my $class = __PACKAGE__ . "::$subclass";
            $class->unregister_class($c);
        }
        return undef;
    }

    return undef if not $message;
    # TODO I guess this hash item should be deleted from PriceDaemon becuase it has useless now.
    delete $message->{price_daemon_cmd};
    $self->do_handle_message($message);
    return undef;

}

requires 'do_handle_message';

sub _is_response_or_self_invalid {
    my ($self, $type, $response, $additional_params_to_check) = @_;
    my $err = !$response || $response->{error};

    for my $key (@{$additional_params_to_check || []}) {
        $err ||= !$self->args->{$key};
    }

    return $err ? $self->_create_error_message($type, $response) : undef;
}

sub _create_error_message {
    my ($self, $type, $response) = @_;
    my ($err_code, $err_message, $err_details);
    my $c = $self->c;
    Binary::WebSocketAPI::v3::Subscription->unregister_by_uuid($c, $self->uuid());

    if ($response->{error}) {
        $err_code    = $response->{error}->{code};
        $err_details = $response->{error}->{details};
        # in pricer_dameon everything happens in Eng to maximize the collisions.
        $err_message = $c->l($response->{error}->{message_to_client});
    } else {
        $err_code    = 'InternalServerError';
        $err_message = 'Internal server error';
        $log->warnf('Pricer "%s" stream event processing error: %s', $type, ($response ? "stash data missed" : "empty response from pricer daemon"));
    }
    my $err = $c->new_error($type, $err_code, $err_message);
    $err->{error}->{details} = $err_details if $err_details;

    return $err;
}

=head2 subscribe

subscribe the channel and store channel to Redis so that pricer_queue script can handle them

=cut

before subscribe => sub {
    my $self = shift;
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_pricer_manager()->redis->sadd($self->pricer_args, $self->subchannel);
};

1;
