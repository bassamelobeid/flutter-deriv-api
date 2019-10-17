package Binary::WebSocketAPI::v3::Subscription::Pricer;

use strict;
use warnings;
no indirect;
use feature qw(state);

use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Wrapper::Pricer;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);
use Time::HiRes qw(gettimeofday tv_interval);
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

a hash that be used to cache something, like proposal_array_subscription in Pricer::ProposalArrayItem, contract_parameters in Proposal

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
    is => 'ro',
    required => 1,
);

=head1 METHODS

=head2 subscription_manager

The SubscriptionManager instance that will manage this worker

=cut

sub subscription_manager {
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_pricer_manager();
}

=head2 subscribe

subscribe the channel and store channel to Redis so that pricer_queue script can handle them

=cut

before subscribe => sub {
    my $self = shift;
    $self->subscription_manager->redis->set($self->pricer_args, 1);
};

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
        for my $subclass (qw(Proposal ProposalOpenContract ProposalArray)) {
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

sub _non_binary_price_adjustment {
    my ($self, $c, $contract_parameters, $results) = @_;

    my $t = [gettimeofday];
    #do app markup adjustment here
    my $app_markup_percentage = $contract_parameters->{app_markup_percentage} // 0;
    my $theo_price            = $contract_parameters->{theo_price}            // 0;
    my $multiplier            = $contract_parameters->{multiplier}            // 0;

    my $app_markup_per_unit = $theo_price * $app_markup_percentage / 100;
    my $app_markup          = $multiplier * $app_markup_per_unit;

    #Currently we only have 2 non binary contracts, lookback and callput spread
    #Callput spread has maximum ask price
    my $adjusted_ask_price = $results->{ask_price} + $app_markup;
    $adjusted_ask_price = min($contract_parameters->{maximum_ask_price}, $adjusted_ask_price)
        if exists $contract_parameters->{maximum_ask_price};

    $results->{ask_price} = $results->{display_value} =
        financialrounding('price', $contract_parameters->{currency}, $adjusted_ask_price);
    stats_timing('price_adjustment.timing', 1000 * tv_interval($t));

    return $results;
}

sub _binary_price_adjustment {
    my ($self, $c, $contract_parameters, $results) = @_;

    my $resp_theo_probability = $contract_parameters->{theo_probability};

    # log the instances when pricing server doesn't return theo probability
    unless (defined $resp_theo_probability) {
        $log->warnf(
            'missing theo probability from pricer. Contract parameter dump %s, pricer response: %s',
            encode_json_text($contract_parameters),
            encode_json_text($results));
        stats_inc('price_adjustment.missing_theo_probability');
    }

    my $t = [gettimeofday];
    # overrides the theo_probability which take the most calculation time.
    # theo_probability is a calculated value (CV), overwrite it with CV object.
    # TODO Is this something we'd want to do here? Looks like something straight out of BOM-Product-Contract...
    # Can we move it out of websocket-api ?
    my $theo_probability = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theo_probability',
        description => 'theorectical value of a contract',
        set_by      => 'Pricer Daemon',
        base_amount => $resp_theo_probability,
        minimum     => 0,
        maximum     => 1,
    });

    $contract_parameters->{theo_probability} = $theo_probability;

    my $price_calculator = Price::Calculator->new(%$contract_parameters);
    # TODO from Zakame: I think this shouldn't be here; websocket-api is supposed to be an interface only, and in particular here should only concern with managing subscriptions, rather than calling pricing methods without the RPC (even for the fallback case.)
    if (my $error = $price_calculator->validate_price) {
        state $error_map = {
            zero_stake             => sub { "Invalid stake/payout." },
            payout_too_many_places => sub {
                my ($details) = @_;
                return ('Payout can not have more than [_1] decimal places.', $details->[0]);
            },
            stake_too_many_places => sub {
                my ($details) = @_;
                return ('Stake can not have more than [_1] decimal places.', $details->[0]);
            },
            stake_same_as_payout => sub {
                'This contract offers no return.';
            },
            stake_outside_range => sub {
                my ($details) = @_;
                return ('Minimum stake of [_1] and maximum payout of [_2]. Current stake is [_3].', $details->[0], $details->[1], $details->[2]);
            },
            payout_outside_range => sub {
                my ($details) = @_;
                return ('Minimum stake of [_1] and maximum payout of [_2]. Current stake is [_3].', $details->[0], $details->[1], $details->[2]);
            },
        };
        return {
            error => {
                message_to_client => $c->l($error_map->{$error->{error_code}}->($error->{error_details} || [])),
                code              => 'ContractBuyValidationError',
                details           => {
                    longcode      => $c->l($contract_parameters->{longcode}),
                    display_value => $price_calculator->ask_price,
                    payout        => $price_calculator->payout,
                },
            }};
    }

    $results->{ask_price} = $results->{display_value} = $price_calculator->ask_price;
    $results->{payout} = $price_calculator->payout;
    $results->{$_} .= '' for qw(ask_price display_value payout);
    stats_timing('price_adjustment.timing', 1000 * tv_interval($t));

    return $results;
}

sub _price_stream_results_adjustment {
    my ($self, $c, $cache, $results) = @_;

    my $contract_parameters = $cache->{contract_parameters};

    if ($contract_parameters->{non_binary_price_adjustment}) {
        return $self->_non_binary_price_adjustment($c, $contract_parameters, $results);
    }

    if ($contract_parameters->{binary_price_adjustment}) {
        return $self->_binary_price_adjustment($c, $contract_parameters, $results);
    }

    return $results;
}

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
    Binary::WebSocketAPI::v3::Subscription->unregister_by_uuid($c, $self->cache->{proposal_array_subscription} || $self->uuid());

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

1;
