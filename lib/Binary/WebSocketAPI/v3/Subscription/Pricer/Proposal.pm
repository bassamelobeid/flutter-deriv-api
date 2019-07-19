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
    my ($self, $message) = @_;
    my $c                = $self->c;
    my $type             = 'proposal';
    my $theo_probability = delete $message->{theo_probability};

    my $results;
    if ($results = $self->_is_response_or_self_invalid($type, $message, ['contract_type'])) {
        stats_inc('price_adjustment.validation_for_type_failure', {tags => ['type:' . $type]});
    } else {
        $self->cache->{contract_parameters}->{longcode} = $self->cache->{longcode};
        my $adjusted_results = $self->_price_stream_results_adjustment($c, $self->cache, $message, $theo_probability);
        if (my $ref = $adjusted_results->{error}) {
            my $err = $c->new_error($type, $ref->{code}, $ref->{message_to_client});
            $err->{error}->{details} = $ref->{details} if exists $ref->{details};
            $results = $err;
            stats_inc('price_adjustment.adjustment_failure', {tags => ['type:' . $type]});
        } else {
            $results = {
                msg_type => $type,
                $type    => {
                    %$adjusted_results,
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

1;
