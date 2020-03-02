package Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalOpenContract;
use strict;
use warnings;
no indirect;

use DataDog::DogStatsd::Helper qw/stats_timing/;
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
        my $passed_fields = $self->cache;

        $message->{id}              = $self->uuid;
        $message->{transaction_ids} = $passed_fields->{transaction_ids};
        $message->{buy_price}       = $passed_fields->{buy_price};
        $message->{purchase_time}   = $passed_fields->{purchase_time};
        $message->{is_sold}         = $passed_fields->{is_sold};
        if ($message->{buy_price} and $message->{bid_price} and $message->{currency}) {
            my $deal_cancellation = $message->{deal_cancellation};
            # we need to exclude cost of cancellation in profit/loss calculation to avoid confusion since
            # pnl always refers to the main contract.
            my $main_contract_price = $deal_cancellation ? $message->{buy_price} - $deal_cancellation->{ask_price} : $message->{buy_price};
            $message->{profit} = formatnumber('price', $message->{currency}, $message->{bid_price} - $main_contract_price);
            $message->{profit_percentage} = roundcommon(0.01, $message->{profit} / $main_contract_price * 100);
        }
        $self->unregister
            if $message->{is_sold};
        $message->{longcode} = $passed_fields->{longcode};

        $message->{contract_id} = $self->args->{contract_id} if exists $self->args->{contract_id};
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

    if (exists $results->{$type} and not $message->{is_expired}) {
        my $tags = [
            'contract_type:' . ($message->{contract_type} // ''),
            'underlying:' .    ($message->{underlying}    // ''),
            'tick_count:' .    ($message->{tick_count}    // ''),
        ];
        stats_timing('bom_websocket_api.v_3.poc.timing', 1000 * (time - $message->{current_spot_time}), {tags => $tags});
    }

    return;
}

# DEMOLISH in subclass will prevent super ROLE's DEMOLISH in Subscription.pm. So here `before` is used.
before DEMOLISH => sub {
    my ($self, $global) = @_;
    return undef if $global;
    return undef unless $self->c;
    # We don't want to track this poc's selling action when we unsubscribe this stream
    my @txn_subscriptons = Binary::WebSocketAPI::v3::Subscription::Transaction->get_by_class($self->c);
    for my $s (@txn_subscriptons) {
        $s->unregister if ($s->type eq 'sell' && $s->poc_uuid eq $self->uuid);
    }
    return undef;
};

1;
