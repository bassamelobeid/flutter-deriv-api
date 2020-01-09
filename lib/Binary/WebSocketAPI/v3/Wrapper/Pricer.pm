package Binary::WebSocketAPI::v3::Wrapper::Pricer;

use strict;
use warnings;

no indirect;

use feature qw(state);
use curry;
use Try::Tiny;
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

use Future::Mojo          ();
use Future::Utils         ();
use Variable::Disposition ();

use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Wrapper::Transaction;
use Binary::WebSocketAPI::v3::Subscription::Pricer::Proposal;
use Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalOpenContract;
use Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalArray;
use Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalArrayItem;

# Number of RPC requests a single active websocket call
# can issue in parallel. Used for proposal_array.
use constant PARALLEL_RPC_COUNT => 4;

# How long we'll wait for all component requests to complete
# Since this is pricing code, anything more than a few seconds
# isn't going to be much use to anyone.
use constant PARALLEL_RPC_TIMEOUT => 20;

# We split proposal_array calls into batches so that we don't
# overload a single RPC server - this controls how many barriers
# we expect to be reasonable for each call.
use constant BARRIERS_PER_BATCH => 16;

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
                    longcode            => $rpc_response->{longcode},
                    contract_parameters => delete $rpc_response->{contract_parameters},
                    payout              => $rpc_response->{payout},
                };
                $cache->{contract_parameters}->{app_markup_percentage} = $c->stash('app_markup_percentage');
                $req_storage->{uuid} = _pricing_channel_for_proposal($c, $req_storage->{args}, $cache, 'Proposal')->{uuid};
            },
            response => sub {
                my ($rpc_response, $api_response, $req_storage) = @_;
                return $api_response if $rpc_response->{error};

                $api_response->{passthrough} = $req_storage->{args}->{passthrough} if defined($req_storage->{args}->{passthrough});
                if (my $uuid = $req_storage->{uuid}) {
                    $api_response->{proposal}->{id} = $uuid;
                    $api_response->{subscription}->{id} = $uuid if $req_storage->{args}->{subscribe};
                } else {
                    $api_response = $c->new_error('proposal', 'AlreadySubscribed', $c->l('You are already subscribed to [_1].', 'proposal'));
                }
                return $api_response;
            },
        });
    return;
}

=head2 proposal_array

Deprecated API call. TODO: (JB) This will be refactored to support multiplier.

Pricing proposals for multiple barriers.

Issues a separate RPC request for each barrier, then collates the results
in a single response back to the client.

=cut

# perlcritic seems to be confused about the fmap block, hence this workaround
sub proposal_array {    ## no critic(Subroutines::RequireArgUnpacking)
    my ($c, $req_storage) = @_;

    my $msg_type       = 'proposal_array';
    my $barriers_order = {};
    my @barriers       = @{$req_storage->{args}->{barriers}};

    if (@barriers > BARRIER_LIMIT) {
        my $error = $c->new_error('proposal_array', 'TooManyBarriers', $c->l('Too many barriers were requested.'));
        $c->send({json => $error}, $req_storage);
        return;
    }

    if (!_unique_barriers(\@barriers)) {
        my $error = $c->new_error('proposal_array', 'DuplicatedBarriers', $c->l('Duplicate barriers not allowed.'));
        $c->send({json => $error}, $req_storage);
        return;
    }

    # We can end up with 10 barriers or more, and each one has a CPU cost, so we limit each
    # request and distribute between RPC servers and pricers.
    my $barrier_chunks = [List::UtilsBy::bundle_by { [@_] } BARRIERS_PER_BATCH, @barriers];

    my $copy_args = {%{$req_storage->{args}}};
    my @contract_types = ref($copy_args->{contract_type}) ? @{$copy_args->{contract_type}} : $copy_args->{contract_type};

    $copy_args->{skip_streaming} =
        1;    # only for proposal_array: do not create redis subscription, we need only information stored in subscription object
    my $channel_info = _pricing_channel_for_proposal($c, $copy_args, {}, 'ProposalArray');
    my $uuid = $channel_info->{uuid};
    unless ($uuid) {
        my $error = $c->new_error('proposal_array', 'AlreadySubscribed', $c->l('You are already subscribed to [_1].', 'proposal_array'));
        $c->send({json => $error}, $req_storage);
        return;
    }
    weaken(my $subscription = $channel_info->{subscription});
    $subscription->req_args($req_storage->{args});

    for my $index ($#$barrier_chunks) {
        my $barrier = $barrier_chunks->[$index];
        $barriers_order->{make_barrier_key($barrier->[0])} = $index;
    }

    my $create_price_channel = sub {
        my ($c, $rpc_response, $req_storage) = @_;
        my $cache = {
            proposal_array_subscription => $subscription->uuid,
        };
        # Apply contract parameters - we will use them for Price::Calculator calls to determine
        # the actual price from the theo_probability value the pricers return
        for my $contract_type (keys %{$rpc_response->{proposals}}) {
            for my $barrier (@{$rpc_response->{proposals}{$contract_type}}) {
                my $barrier_key = make_barrier_key($barrier->{error} ? $barrier->{error}->{details} : $barrier);
                my $entry = {
                    %{$rpc_response->{contract_parameters}},
                    longcode  => $barrier->{longcode},
                    ask_price => $barrier->{ask_price},
                };
                delete @{$entry}{qw(proposals barriers)};
                $entry->{error}{details}{longcode} ||= $entry->{longcode} if $entry->{error};
                $cache->{$contract_type}{$barrier_key} = {
                    contract_parameters => $entry,
                };
            }
        }

        $req_storage->{uuid} = _pricing_channel_for_proposal($c, $req_storage->{args}, $cache, 'ProposalArrayItem')->{uuid};

        if ($req_storage->{uuid}) {
            my $barriers = $req_storage->{args}{barriers}[0];
            my $idx      = make_barrier_key($barriers);
            warn "unknown idx " . $idx . ", available: " . join ',', sort keys %$barriers_order unless exists $barriers_order->{$idx};
            ${$subscription->seq}[$barriers_order->{$idx}] = $req_storage->{uuid};
            # creating this key to be used by forget_all, undef - not to allow proposal_array message to be sent before real data received
            $subscription->proposals->{$req_storage->{uuid}} = undef;
        } else {
            # `_pricing_channel_for_proposal` does not generated uuid.
            # it could be rare case when 2 proposal_array calls are performed in one connection
            # and they have similar but not the same barriers, so some chunks became the same
            # in this case `proposal_array` RPC hook `response` will send error message to client and will stop processing this call
            # so subscription should be removed.
            $subscription->unregister;
        }
    };

# Process a few RPC calls at a time.

    Variable::Disposition::retain_future(
        Future->wait_any(
            # Upper limit on total time taken - we don't really
            # care how long individual requests take, but we do
            # expect all the calls to complete in a reasonable time
            Future::Mojo->new_timer(PARALLEL_RPC_TIMEOUT)->transform(
                done => sub {
                    return +{error => $c->l('Request timed out')};
                }
            ),
            Future::Utils::fmap {
                my $barriers = shift;

                # The format is [ 123.4, 128.1, ... ] for single-barrier contracts,
                # with hashrefs [ { barrier => 121.8, barrier2 => 127.4 }, ... ] for 2-barrier
                $barriers = [map { ; $_->{barrier} } @$barriers] unless grep { ; $_->{barrier2} } @$barriers;

                # Shallow copy of $args since we want to override a few top-level keys for the RPC calls
                my $args = {%{$req_storage->{args}}};
                $args->{contract_type} = [@contract_types];
                $args->{barriers}      = $barriers;

                my $f = Future::Mojo->new;
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
                            proposal_array        => 1,
                        },
                        error => sub {
                            my $c = shift;
                            Binary::WebSocketAPI::v3::Wrapper::System::forget_one($c, $uuid);
                        },
                        success  => $create_price_channel,
                        response => sub {
                            my ($rpc_response, $api_response, $req_storage) = @_;
                            if ($rpc_response->{error}) {
                                $f->done($api_response);
                                return;
                            }

                            # here $api_response and $req_storage are `proposal` call's data, not the original `proposal_array`
                            # so uuid here is corresponding `proposal` stream's uuid.
                            # uuid for `proposal_array` is created on the beginning of `sub proposal_array`
                            if (my $uuid = $req_storage->{uuid}) {
                                $api_response->{proposal}->{id} = $uuid;
                            } else {
                                $api_response =
                                    $c->new_error('proposal', 'AlreadySubscribed', $c->l('You are already subscribed to [_1].', 'proposal'));
                            }
                            $f->done($api_response);
                            return;
                        },
                    });
                $f;
            }
            foreach    => $barrier_chunks,
            concurrent => min(0 + @$barrier_chunks, PARALLEL_RPC_COUNT),
            )->on_ready(
            sub {
                my $f = shift;
                try {
                    # should not throw 'cos we do not $future->fail
                    my @result = $f->get;

                    # If any request failed, report the error and skip any further processing
                    # Note that this is an RPC-level error or WrongResponse: contract validation
                    # failures for an individual barrier will be reported at the type => [ barrier ]
                    # level.
                    if (my ($err) = grep { ; $_->{error} } @result) {
                        my $res = {
                            json => {
                                echo_req => $req_storage->{args},
                                error    => $err->{error},
                                msg_type => $msg_type,
                                map { ; $_ => $req_storage->{args}{$_} } grep { $req_storage->{args}{$_} } qw(req_id passthrough),
                            }};
                        $c->send($res) if $c and $c->tx;    # connection could be gone
                        return;
                    }

                    # Merge the results from all calls. We prepare the data structure first...
                    my %proposal_array;
                    @proposal_array{@contract_types} = map { ; [] } @contract_types;

                    # ... then fit the received results into it
                    my @pending_barriers = @barriers;
                    for my $res (map { ; $_->{proposal} } @result) {
                        my @expected_barriers = splice @pending_barriers, 0, min(@pending_barriers, BARRIERS_PER_BATCH);
                        if (exists $res->{proposals}) {
                            for my $contract_type (keys %{$res->{proposals}}) {
                                my @prices = @{$res->{proposals}{$contract_type}};
                                for my $price (@prices) {
                                    if (exists $price->{error}) {
                                        $price->{error}{message} = $c->l(delete $price->{error}{message_to_client});
                                        $price->{error}{details}{longcode} = $c->l(delete $price->{longcode});
                                        $price->{error}{details}{display_value} += 0;
                                        $price->{error}{details}{payout}        += 0;
                                        delete $price->{error}{details}{supplied_barrier};
                                        delete $price->{error}{details}{supplied_barrier2};
                                    } else {
                                        $price->{longcode} = $c->l($price->{longcode});
                                        $price->{payout}   = $req_storage->{args}{amount};
                                        delete $price->{theo_probability};
                                        delete $price->{supplied_barrier};
                                        delete $price->{supplied_barrier2};
                                    }
                                }
                                warn "Barrier mismatch - expected " . @expected_barriers . " but had " . @prices unless @prices == @expected_barriers;
                                push @{$proposal_array{$contract_type}}, @prices;
                            }
                        } else {
                            # We've already done the check for top-level { error => { ... } } by this point,
                            # so if we don't have the proposals key then something very unexpected happened.
                            warn "Invalid entry in proposal_array response - " . $json->encode($res);
                            $c->send({
                                    json => $c->wsp_error(
                                        $msg_type, 'ProposalArrayFailure', $c->l('Sorry, an error occurred while processing your request.'))}
                            ) if $c and $c->tx;
                            return;
                        }
                    }

                    delete @{$_}{qw(msg_type passthrough)} for @result;

                    # Return a single result back to the client.
                    my $res = {
                        json => {
                            echo_req       => $req_storage->{args},
                            proposal_array => {
                                proposals => \%proposal_array,
                                $uuid ? (id => $uuid) : (),
                            },
                            ($req_storage->{args}->{subscribe} and $uuid) ? (subscription => {id => $uuid}) : (),
                            msg_type => $msg_type,
                            map { ; $_ => $req_storage->{args}{$_} } grep { $req_storage->{args}{$_} } qw(req_id passthrough),
                        }};
                    $c->send($res) if $c and $c->tx;    # connection could be gone
                }
                catch {
                    warn "proposal_array exception - $_";
                    $c->send(
                        {json => $c->wsp_error($msg_type, 'ProposalArrayFailure', $c->l('Sorry, an error occurred while processing your request.'))})
                        if $c and $c->tx;
                };
            }));

# Send nothing back to the client yet. We'll push a response
# once the RPC calls complete or time out
    return;
}

sub proposal_array_deprecated {
    my ($c, $req_storage) = @_;

    my $dep_error = $c->new_error('proposal_array', 'Deprecated', $c->l('This API call is deprecated.'));
    $c->send({json => $dep_error}, $req_storage);
    return;
}

sub proposal_open_contract {
    my ($c, $response, $req_storage) = @_;

    # send error early if whole RPC call returns error - for example 'InvalidToken'
    if ($response->{error}) {
        $c->send({json => $c->new_error('proposal_open_contract', $response->{error}{code}, $response->{error}{message_to_client})}, $req_storage);
        return;
    }

    my $args = $req_storage->{args};

    if ($args->{subscribe} && !$args->{contract_id}) {
        ### we can catch buy only if subscribed on transaction stream
        Binary::WebSocketAPI::v3::Wrapper::Transaction::transaction_channel($c, 'subscribe', $c->stash('account_id'), 'buy', $args)
            if $c->stash('account_id');
        ### we need stream only in subscribed workers
        # we should not overwrite the previous subscriber.
        $c->stash(proposal_open_contracts_subscribed => $args) unless $c->stash('proposal_open_contracts_subscribed');
    }

    my $empty_answer = {
        msg_type               => 'proposal_open_contract',
        proposal_open_contract => {}};
    # If we had a valid response, we can return it immediately
    if (%$response) {
        _process_proposal_open_contract_response($c, $response, $req_storage);
        return;
    }

    # If we're not looking for a specific contract_id, then an empty response is fine
    return $empty_answer unless $args->{contract_id};

    # special case: 'proposal_open_contract' with contract_id set called immediately after 'buy'
    # could return empty response because of DB replication delay
    # so here retries are performed
    my $last_contracts = $c->stash('last_contracts') // {};
    return $empty_answer unless $last_contracts->{$args->{contract_id}};

    # contract id is in list, but response is empty - trying to retry rpc call
    my $retries = 5;
    my $call_sub;
    # preparing response sub wich will be executed within retries loop
    my $resp_sub = sub {
        my ($rpc_response, $response, $req_storage) = @_;
        # response contains data or rpc error - so no need to retry rpc call
        my $valid_response = %{$response->{proposal_open_contract}} || $rpc_response->{error};

        # empty response and having some tries
        if (!$valid_response && --$retries) {
            # we still have to retry, so sleep a second and perform rpc call again
            Mojo::IOLoop->timer(1, $call_sub);
            return;
        }

        # no need any more
        undef $call_sub;

        return $response if $rpc_response->{error};
        # return empty answer if there is no more retries
        return $empty_answer if !$valid_response;

        # got proper response
        _process_proposal_open_contract_response($c, $response->{proposal_open_contract}, $req_storage);

        return;
    };
    # new rpc call with response sub wich holds delay and re-call
    $call_sub = sub {
        my %call_params = %$req_storage;
        $call_params{response} = $resp_sub;
        $c->call_rpc(\%call_params);
        return;
    };
    # perform rpc call again and entering in retries loop
    $call_sub->($c, $req_storage);

    return;
}

sub _process_proposal_open_contract_response {
    my ($c, $response, $req_storage) = @_;

    my $args = $req_storage->{args};

    foreach my $contract (values %$response) {
        my $pricer_request = {%$contract};

        $pricer_request->{short_code} = $pricer_request->{shortcode}
            if $pricer_request->{shortcode};    # XXX on contract end this is shortcode, other times it's shortcode
        $pricer_request->{landing_company} = $c->landing_company_name;
        $pricer_request->{language}        = $c->stash('language');

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
            my $uuid;

            if (    exists $args->{subscribe}
                and $args->{subscribe} eq '1'
                and not $contract->{is_sold}
                and not delete $contract->{dont_stream})
            {
                # short_code contract_id currency is_sold sell_time are passed to pricer daemon and
                # are used to to identify redis channel and as arguments to get_bid rpc call
                # transaction_ids purchase_time buy_price should be stored and will be added to
                # every get_bid results and sent to client while streaming
                my $cache =
                    {map { $_ => $contract->{$_} }
                        qw(account_id shortcode contract_id currency buy_price sell_price sell_time purchase_time is_sold transaction_ids longcode)};

                $cache->{limit_order} = $contract->{limit_order} if $contract->{limit_order};

                if (not $uuid = pricing_channel_for_proposal_open_contract($c, $args, $cache)->{uuid}) {
                    my $error =
                        $c->new_error('proposal_open_contract', 'AlreadySubscribed',
                        $c->l('You are already subscribed to [_1].', 'proposal_open_contract'));
                    $c->send({json => $error}, $req_storage);
                    return;
                } else {
                    # subscribe to transaction channel as when contract is manually sold we need to cancel streaming
                    Binary::WebSocketAPI::v3::Wrapper::Transaction::transaction_channel(
                        $c, 'subscribe', delete $contract->{account_id},    # should not go to client
                        'sell', $args, $contract->{contract_id}, $uuid
                    );
                }
            }
            my $result = {$uuid ? (id => $uuid) : (), %{$contract}};
            delete $result->{rpc_time};
            delete $result->{account_id};

            # need to restructure limit order for poc response
            $result->{limit_order} = delete $result->{limit_order_as_hashref} if $result->{limit_order_as_hashref};
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

    return 'PRICER_KEYS::' . Encode::encode_utf8($json->encode([map { !defined($_) ? $_ : ref($_) ? $_ : "$_" } @arr]));
}

# This function is for Porposal, ProposalArray and ProposalArrayItem
# TODO rename this function
sub _pricing_channel_for_proposal {
    my ($c, $args, $cache, $class) = @_;

    my $price_daemon_cmd = 'price';

    my %args_hash           = %{$args};
    my $skip_basis_override = _skip_basis_override($args);
    if (not $skip_basis_override and $args_hash{basis} and defined $args_hash{amount}) {
        $args_hash{amount} = 1000;
        $args_hash{basis}  = 'payout';
    }

    delete $args_hash{passthrough};

    $args_hash{language}         = $c->stash('language') || 'EN';
    $args_hash{price_daemon_cmd} = $price_daemon_cmd;
    $args_hash{landing_company}  = $c->landing_company_name;
    # use residence when available, fall back to IP country
    $args_hash{country_code} = $c->stash('residence') || $c->stash('country_code');
    $args_hash{skips_price_validation} = 1;
    my $redis_channel = _serialized_args(\%args_hash);
    my $subchannel    = $args->{amount} // $args->{multiplier};
    my $pricer_args   = $redis_channel;

    my $skip = _skip_streaming($args);

    # uuid is needed regardless of whether its subscription or not
    return _create_pricer_channel($c, $args, $redis_channel, $subchannel, $pricer_args, $class, $cache, $skip);
}

sub pricing_channel_for_proposal_open_contract {
    my ($c, $args, $cache) = @_;

    my $contract_id     = $cache->{contract_id};
    my $landing_company = $c->landing_company_name;

    my $redis_channel = join '::', ('CONTRACT_PRICE', $contract_id, $landing_company);
    my $pricer_args = _serialized_args({
        contract_id     => $contract_id,
        landing_company => $landing_company,
    });

    my %hash = map { $_ =~ /passthrough/ ? () : ($_ => $args->{$_}) } keys %$args;
    $hash{account_id}     = delete $cache->{account_id};
    $hash{transaction_id} = $cache->{transaction_ids}->{buy};    # transaction is going to be stored
    my $subchannel = _serialized_args(\%hash);

    return _create_pricer_channel($c, $args, $redis_channel, $subchannel, $pricer_args, 'ProposalOpenContract', $cache);
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

#
# we're finishing POC stream on contract is sold (called from _close_proposal_open_contract_stream in Streamer.pm)
#
sub send_proposal_open_contract_last_time {
    my ($c, $args, $contract_id, $stash_data) = @_;
    Binary::WebSocketAPI::v3::Subscription->unregister_by_uuid($c, $args->{uuid});

    $c->call_rpc({
            args        => $stash_data,
            method      => 'proposal_open_contract',
            msg_type    => 'proposal_open_contract',
            call_params => {
                token       => $c->stash('token'),
                contract_id => $contract_id
            },
            rpc_response_cb => sub {
                my ($c, $rpc_response, $req_storage) = @_;

                for my $each_contract (keys %{$rpc_response}) {
                    delete $rpc_response->{$each_contract}->{account_id};
                    $rpc_response->{$each_contract}->{limit_order} = delete $rpc_response->{$each_contract}->{limit_order_as_hashref}
                        if $rpc_response->{$each_contract}->{limit_order_as_hashref};
                }
                return {
                    proposal_open_contract => $rpc_response->{$contract_id} || {},
                    msg_type => 'proposal_open_contract',
                    subscription => {id => $args->{uuid}}};
            }
        });
    return;
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
    # In proposal_array we use barriers to order proposals[] array responses.
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

my %skip_duration_list = map { $_ => 1 } qw(t s m h);
my %skip_symbol_list   = map { $_ => 1 } qw(R_100 R_50 R_25 R_75 R_10 RDBULL RDBEAR 1HZ100V 1HZ10V);
my %skip_type_list =
    map { $_ => 1 } qw(DIGITMATCH DIGITDIFF DIGITOVER DIGITUNDER DIGITODD DIGITEVEN ASIAND ASIANU TICKHIGH TICKLOW RESETCALL RESETPUT);

sub _skip_streaming {
    my $args = shift;

    return 1 if $args->{skip_streaming};
    my $skip_symbols = ($skip_symbol_list{$args->{symbol}}) ? 1 : 0;
    my $atm_callput_contract =
        ($args->{contract_type} =~ /^(CALL|PUT|CALLE|PUTE)$/ and not($args->{barrier} or ($args->{proposal_array} and $args->{barriers})))
        ? 1
        : 0;

    my ($skip_atm_callput, $skip_contract_type) = (0, 0);

    if (defined $args->{duration_unit}) {

        $skip_atm_callput =
            ($skip_symbols and $skip_duration_list{$args->{duration_unit}} and $atm_callput_contract);

        $skip_contract_type = ($skip_symbols and $skip_type_list{$args->{contract_type}});

    }

    return 1 if ($skip_atm_callput or $skip_contract_type);
    return;
}

sub _skip_basis_override {
    my $args = shift;

    # to override multiplier or callputspread contracts (non-binary) just does not make any sense because
    # the ask_price is defined by the user and the output of limit order (take profit or stop out),
    # is dependent of the stake and multiplier provided by the client.
    #
    # There is no probability calculation involved. Hence, not optimising anything.
    return 1 if $args->{contract_type} =~ /^(MULTUP|MULTDOWN|CALLSPREAD|PUTSPREAD)$/;
    return 0;
}

1;
