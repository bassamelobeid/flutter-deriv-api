package Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalArrayItem;
use strict;
use warnings;
no indirect;

use Log::Any qw($log);
use Try::Tiny;
use Moo;
with 'Binary::WebSocketAPI::v3::Subscription::Pricer';
use namespace::clean;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalArrayItem - The class that handle proposal array item channels

=head1 DESCRIPTION

This module is the interface for pricer proposal array item subscription-related tasks
Please refer to L<Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalArray>

=cut

# The messages are processed in 2 phrase:
# 1. process the message and store the information into proposal arrray object
# 2. run collector to collect the information from proposal array object and send to client
sub do_handle_message {
    my ($self, $message) = @_;
    my $c = $self->c;
    my $array_subscription = $self->get_by_uuid($self->c, $self->cache->{proposal_array_subscription});
    unless ($array_subscription) {
        $self->unregister;
        return undef;
    }

    my $type = 'proposal';

    unless ($c->stash('proposal_array_collector_running')) {
        $c->stash('proposal_array_collector_running' => 1);
        # start 1 sec proposal_array sender if not started yet
        # see lib/Binary/WebSocketAPI/Plugins/Helpers.pm line ~ 178
        __PACKAGE__->_proposal_array_collector($c);
    }

    $self->cache->{contract_parameters}{currency} ||= $self->args->{currency};
    my %proposals;
    for my $contract_type (keys %{$message->{proposals}}) {
        $proposals{$contract_type} = (my $barriers = []);
        for my $price (@{$message->{proposals}{$contract_type}}) {
            my $result = try {
                if (my $invalid = $self->_is_response_or_self_invalid($type, $message, ['contract_type'])) {
                    $log->warnf('%s process_proposal_array_event: _get_validation_for_type failed, results: %s',
                        $self->class, encode_json_text($invalid));
                    return $invalid;
                } elsif (exists $price->{error}) {
                    return $price;
                } else {
                    my $barrier_key      = Binary::WebSocketAPI::v3::Wrapper::Pricer::make_barrier_key($price);
                    my $theo_probability = delete $price->{theo_probability};
                    delete $price->{supplied_barrier};
                    delete $price->{supplied_barrier2};
                    my $stashed_contract_parameters = $self->cache->{$contract_type}{$barrier_key};
                    $stashed_contract_parameters->{contract_parameters}{currency} ||= $self->args->{currency};
                    $stashed_contract_parameters->{contract_parameters}{$stashed_contract_parameters->{contract_parameters}{amount_type}} =
                        $stashed_contract_parameters->{contract_parameters}{amount};
                    delete $stashed_contract_parameters->{contract_parameters}{ask_price};

                    # Make sure that we don't override any of the values for next time (e.g. ask_price)
                    my $copy = {contract_parameters => {%{$stashed_contract_parameters->{contract_parameters}}}};
                    my $res = $self->_price_stream_results_adjustment($c, $copy, $price, $theo_probability);
                    $res->{longcode} = $c->l($res->{longcode}) if $res->{longcode};
                    return $res;
                }
            }
            catch {
                $log->warnf('%s Failed to apply price - $s - with a price struc containing %s', $self->class, $_, Dumper($price));
                return +{
                    error => {
                        message_to_client => $c->l('Sorry, an error occurred while processing your request.'),
                        code              => 'ContractValidationError',
                        details           => {
                            barrier => $price->{barrier},
                            (exists $price->{barrier2} ? (barrier2 => $price->{barrier2}) : ()),
                        },
                    }};
            };

            if (exists $result->{error}) {
                $result->{error}{details}{barrier} //= $price->{barrier};
                $result->{error}{details}{barrier2} //= $price->{barrier2} if exists $price->{barrier2};
            }
            push @$barriers, $result;
        }
    }

    $array_subscription->proposals->{$self->uuid} = \%proposals;

    return undef;

}

sub _proposal_array_collector {
    my ($class, $c) = @_;
    Scalar::Util::weaken(my $weak_c = $c);
    # send proposal_array stream messages collected from appropriate proposal streams
    my $proposal_array_loop_id_keeper;
    $proposal_array_loop_id_keeper = Mojo::IOLoop->recurring(
        1,
        sub {
            # It's possible for the client to disconnect before we're finished.
            # If that happens, make sure we clean up but don't attempt to process any further.
            unless ($weak_c && $weak_c->tx) {
                Mojo::IOLoop->remove($proposal_array_loop_id_keeper);
                return undef;
            }

            my @pa_subs = Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalArray->get_by_class($weak_c);
            PA_LOOP:
            for my $sub (@pa_subs) {
                my $pa_uuid = $sub->uuid;
                my %proposal_array;
                for my $i (0 .. $#{$sub->seq}) {
                    my $uuid = $sub->seq->[$i];
                    unless ($uuid) {
                        # this case is hold in `proposal_array` - for some reasons `_pricing_channel_for_proposal`
                        # did not created uuid for one of the `proposal_array`'s `proposal` calls
                        # subscription anyway is broken - so remove it
                        # see sub proposal_array for details
                        # error messge is already sent by `response` RPC hook.
                        $sub->unregister;
                        next PA_LOOP;
                    }
                    my $barriers = $sub->args->{barriers}[$i];
                    # Bail out early if we have any streams without a response yet
                    my $proposal = $sub->proposals->{$uuid} or return undef;
                    for my $contract_type (keys %$proposal) {
                        for my $price (@{$proposal->{$contract_type}}) {
                            # Ensure we have barriers
                            if ($price->{error}) {
                                $price->{error}{details}{barrier} //= $barriers->{barrier};
                                $price->{error}{details}{barrier2} //= $barriers->{barrier2} if exists $barriers->{barrier2};
                                $price->{error}{message} = delete $price->{error}{message_to_client}
                                    if exists $price->{error}{message_to_client};
                            }
                            push @{$proposal_array{$contract_type}}, $price;
                        }
                    }
                }

                my $results = {
                    proposal_array => {
                        proposals => \%proposal_array,
                        id        => $pa_uuid,
                    },
                    echo_req     => $sub->req_args,
                    msg_type     => 'proposal_array',
                    subscription => {id => $pa_uuid},
                };
                $weak_c->send({json => $results}, {args => $sub->req_args});
            }
            return undef;
        });
    return undef;
}

1;
