package Binary::WebSocketAPI::v3::Subscription::Pricer::Proposal;
use strict;
use warnings;
no indirect;

use Moo;
use DataDog::DogStatsd::Helper qw(stats_inc);
with 'Binary::WebSocketAPI::v3::Subscription::Pricer';
use namespace::clean;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::Pricer::Proposal - The class that handle proposal channels

=head1 DESCRIPTION

This module is the interface for pricer proposal subscription-related tasks
Please refer to L<Binary::WebSocketAPI::v3::Subscription>

=cut

sub do_handle_message {
    my ($self, $response) = @_;
    my $c    = $self->c;
    my $type = 'proposal';

    my $results;
    if ($results = $self->_is_response_or_self_invalid($type, $response, ['contract_type'])) {
        stats_inc('price_adjustment.validation_for_type_failure', {tags => ['type:' . $type]});
    } else {
        $self->cache->{contract_parameters}->{longcode} = $self->cache->{longcode};
        if (my $ref = $response->{error}) {
            my $err = $c->new_error($type, $ref->{code}, $ref->{message_to_client});
            $err->{error}->{details} = $ref->{details} if exists $ref->{details};
            $results = $err;
            stats_inc('price_adjustment.adjustment_failure', {tags => ['type:' . $type]});
        } else {
            $results = {
                msg_type => $type,
                $type    => {
                    %$response,
                    id       => $self->uuid,
                    longcode => $c->l($self->cache->{longcode}),
                },
                subscription => {id => $self->uuid},
            };
        }
    }
    if ($c->stash('debug')) {
        $results->{debug} = {
            time   => $results->{$type}->{rpc_time},
            method => $type,
        };
    }
    delete @{$results->{$type}}{qw(contract_parameters rpc_time)} if $results->{$type};
    $c->send({json => $results}, {args => $self->args});
    return;

}

=head2 subscribe

subscribe the channel and store channel to Redis so that pricer_queue script can handle them

=cut

before subscribe => sub {
    my $self = shift;
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_pricer_manager()->redis->sadd($self->pricer_args, $self->subchannel);
};

1;
