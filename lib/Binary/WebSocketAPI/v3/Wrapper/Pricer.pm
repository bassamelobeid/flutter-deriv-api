package Binary::WebSocketAPI::v3::Wrapper::Pricer;

use strict;
use warnings;

no indirect;

use feature qw(state);
use curry;
use Syntax::Keyword::Try;
use Data::Dumper;
use Encode;
use JSON::MaybeXS;
use Time::HiRes qw(gettimeofday tv_interval);
use Math::Util::CalculatedValue::Validatable;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);
use Price::Calculator;
use Clone::PP qw(clone);
use List::UtilsBy qw(bundle_by);
use List::Util qw(min);
use Scalar::Util qw(weaken);
use Log::Any qw($log);

use Future::Mojo          ();
use Future::Utils         ();
use Variable::Disposition ();

use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Wrapper::Transaction;
use Binary::WebSocketAPI::v3::Subscription::Pricer::Proposal;
use Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalOpenContract;

# Number of RPC requests a single active websocket call
# can issue in parallel.
use constant PARALLEL_RPC_COUNT => 4;

# How long we'll wait for all component requests to complete
# Since this is pricing code, anything more than a few seconds
# isn't going to be much use to anyone.
use constant PARALLEL_RPC_TIMEOUT => 20;

# Sanity check - if we have more than this many barriers, reject
# the request entirely.
use constant BARRIER_LIMIT => 16;

my $json = JSON::MaybeXS->new->allow_blessed;

sub proposal {
    my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};
    $c->call_rpc({
            schema_receive    => $req_storage->{schema_receive},
            schema_receive_v3 => $req_storage->{schema_receive_v3},
            args              => $args,
            method            => 'send_ask',
            msg_type          => 'proposal',
            call_params       => {
                token                 => $c->stash('token'),
                language              => $c->stash('language'),
                app_markup_percentage => $c->stash('app_markup_percentage'),
                landing_company       => $c->landing_company_name,
                country_code          => $c->stash('country_code'),
            },
            success => sub {
                my ($c, $rpc_response, $req_storage) = @_;
                my $cache = {
                    longcode             => $rpc_response->{longcode},
                    contract_parameters  => delete $rpc_response->{contract_parameters},
                    payout               => $rpc_response->{payout},
                    skip_streaming       => delete $rpc_response->{skip_streaming} // 0,
                    subscription_channel => delete $rpc_response->{subscription_channel},
                    subchannel           => delete $rpc_response->{subchannel},
                    channel              => delete $rpc_response->{channel},
                };
                $cache->{contract_parameters}->{app_markup_percentage} = $c->stash('app_markup_percentage') // 0;
                $req_storage->{uuid} = _pricing_channel_for_proposal($c, $req_storage->{args}, $cache, 'Proposal')->{uuid};
            },
            response => sub {
                my ($rpc_response, $api_response, $req_storage) = @_;
                return $api_response if $rpc_response->{error};

                $api_response->{passthrough} = $req_storage->{args}->{passthrough} if defined($req_storage->{args}->{passthrough});
                if (my $uuid = $req_storage->{uuid}) {
                    $api_response->{proposal}->{id}     = $uuid;
                    $api_response->{subscription}->{id} = $uuid if $req_storage->{args}->{subscribe};
                } else {
                    $api_response = $c->new_error('proposal', 'AlreadySubscribed', $c->l('You are already subscribed to [_1].', 'proposal'));
                }

                return $api_response;
            },
        });
    return;
}

sub proposal_open_contract {
    my ($c, $response, $req_storage) = @_;

    # send error early if whole RPC call returns error - for example 'InvalidToken'
    if ($response->{error}) {
        $c->send({json => $c->new_error('proposal_open_contract', $response->{error}{code}, $response->{error}{message_to_client})}, $req_storage);
        return;
    }

    my $channel          = delete $response->{channel};
    my $pricer_args_keys = delete $response->{pricer_args_keys};
    my $uuid;
    if (defined $channel) {
        # $channel could be in either
        #   - CONTRACT_PRICE::<landing_company>::<account_id>::<contract_id> or
        #   - CONTRACT_PRICE::<landing_company>::<account_id>::*
        # In the second case, $subscription subscribes to all open contracts.
        my $subscription = Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalOpenContract->new(
            c           => $c,
            channel     => $channel,
            subchannel  => 1,
            pricer_args => $pricer_args_keys // [],
            args        => $req_storage->{args},
            cache       => {});
        if ($subscription->already_registered) {
            my $error = $c->l('You are already subscribed to [_1].', 'proposal_open_contract');
            $c->send({json => $c->new_error('proposal_open_contract', 'AlreadySubscribed', $error)}, $req_storage);
            return;
        }

        $subscription->register();
        $uuid = $subscription->uuid();
        $subscription->subscribe();
    }

    # return one response per open contract
    if (%$response) {
        _process_proposal_open_contract_response($c, $response, $req_storage, $uuid);
        return;
    }

    # TODO: send an error
    # return $empty_answer if $req_storage->{args}->{contract_id};
    my $empty_answer = {
        msg_type               => 'proposal_open_contract',
        proposal_open_contract => {},
        $uuid ? (subscription => {id => $uuid}) : ()};

    return $empty_answer;
}

sub _process_proposal_open_contract_response {
    my ($c, $response, $req_storage, $uuid) = @_;

    foreach my $contract (values %$response) {
        if (exists $contract->{error}) {
            my $error =
                $c->new_error('proposal_open_contract', 'ContractValidationError', $c->l($contract->{error}->{message_to_client}));
            $c->send({json => $error}, $req_storage);
        } elsif (not exists $contract->{shortcode}) {
            my %copy_req = %$req_storage;
            delete @copy_req{qw(in_validator out_validator)};
            $copy_req{loginid} = $c->stash('loginid') if $c->stash('loginid');
            warn "undef shortcode. req_storage is: " . $json->encode(\%copy_req);
            warn "undef shortcode. response is: " . $json->encode($contract);
            my $error =
                $c->new_error('proposal_open_contract', 'GetProposalFailure', $c->l('Sorry, an error occurred while processing your request.'));
            $c->send({json => $error}, $req_storage);
        } else {
            my $result = {$uuid ? (id => $uuid) : (), %{$contract}};
            $c->send({
                    json => {
                        msg_type               => 'proposal_open_contract',
                        proposal_open_contract => $result,
                        $uuid ? (subscription => {id => $uuid}) : (),
                    },
                },
                $req_storage
            );
        }
    }
    return;
}

sub _serialized_args {
    my $copy = {%{+shift}};
    my $args = shift;
    my @arr  = ();

    delete $copy->{req_id};
    delete $copy->{language} unless $args->{keep_language};

    # We want to handle similar contracts together, so we do this and sort by
    # key in the price_queue.pl daemon
    push @arr, ('short_code', delete $copy->{short_code}) if exists $copy->{short_code};

    # Keep country only if it is CN.
    delete $copy->{country_code} if exists $copy->{country_code} and $copy->{country_code} ne 'cn';

    foreach my $k (sort keys %$copy) {
        push @arr, ($k, $copy->{$k});
    }

    return 'PRICER_ARGS::' . Encode::encode_utf8($json->encode([map { !defined($_) ? $_ : ref($_) ? $_ : "$_" } @arr]));
}

sub _serialize_contract_parameters {
    my $args = shift;

    my $staking_limits = $args->{staking_limits} // {};
    return join(
        ",",
        "v1",
        $args->{currency} // '',
        # binary
        $args->{amount}                // '',
        $args->{amount_type}           // '',
        $args->{app_markup_percentage} // '',
        $args->{deep_otm_threshold}    // '',
        $args->{base_commission}       // '',
        $args->{min_commission_amount} // '',
        $staking_limits->{min}         // '',
        $staking_limits->{max}         // '',
        # non-binary
        $args->{maximum_ask_price} // '',    # callputspread is the only contract type that has this
        $args->{multiplier}        // '',
    );
}

sub _pricing_channel_for_proposal {
    my ($c, $args, $cache, $class) = @_;

    my $channel              = $cache->{channel};                 # name of the redis set on redis-pricer holding subchannel's as values.
    my $subchannel           = $cache->{subchannel};              # parameters needed by price-daemon for price-adjustment.
    my $subscription_channel = $cache->{subscription_channel};    # name of the redis channel that price-daemon publishes into.

    # uuid is needed regardless of whether its subscription or not
    return _create_pricer_channel($c, $args, $subscription_channel, $subchannel, $channel, $class, $cache, $cache->{skip_streaming});
}

# will return a hash {uuid => $subscription->uuid, subscription => $subscription}
# here return a hash to avoid caller testing subscription when fetch uuid
sub _create_pricer_channel {
    my ($c, $args, $redis_channel, $subchannel, $pricer_args, $class, $cache, $skip_redis_subscr) = @_;

    my $subscription = create_subscription(
        c           => $c,
        channel     => $redis_channel,
        subchannel  => $subchannel,
        pricer_args => $pricer_args,
        args        => $args,
        cache       => $cache,
        class       => $class
    );

    # channel already generated
    if (my $registered_subscription = $subscription->already_registered) {
        # return undef uuid directly will report 'already subscribed' error by the caller
        return ($args->{subscribe} // 0) == 1
            ? {
            subscription => undef,
            uuid         => undef
            }
            : {
            subscription => $registered_subscription,
            uuid         => $registered_subscription->uuid
            };
    }

    $subscription->register;
    my $uuid = $subscription->uuid();

    #Sometimes we need to store the proposal information here, but we don't want to subscribe a channel.
    #For example, before buying a contract, FE will send a 'proposal'  at first, then when we do buying, `buy_get_contract_params` will access that information. in such case subscribe = 1, but $skip_redis_subscr is true. The information will be cleared when by contract
    # Another example: proposal array
    if (($args->{subscribe} // 0) == 1
        and not $skip_redis_subscr)
    {
        $subscription->subscribe();
    }

    return {
        subscription => $subscription,
        uuid         => $uuid
    };
}

sub _unique_barriers {
    my $barriers = shift;
    my %h;
    for my $barrier (@$barriers) {
        my $idx = $barrier->{barrier} // '' . ":" . ($barrier->{barrier2} // '');
        return 0 if $h{$idx}++;
    }
    return 1;
}

sub make_barrier_key {
    my ($barrier) = @_;
    return $barrier unless ref $barrier;

    # Even if it's a relative barrier, for that Contract->handle_batch_contract also sends the supplied barrier back.
    if (exists $barrier->{supplied_barrier}) {
        return join ':', $barrier->{supplied_barrier}, $barrier->{supplied_barrier2} // ();
    }
    return join ':', $barrier->{barrier} // (), $barrier->{barrier2} // ();
}

=head2 create_subscription

create subscription given the subscription type. It map the price_daemon_cmd to the proper Subscription subclass.
It takes the following arguments:

=over 4

=item price_daemon_cmd

=item other arguments that are used by subscription constructor.

=back

It returns a subscription  object

=cut

sub create_subscription {
    my (%args)    = @_;
    my $baseclass = 'Binary::WebSocketAPI::v3::Subscription::Pricer';
    my $class     = delete $args{class};
    return "${baseclass}::$class"->new(%args);
}

1;
