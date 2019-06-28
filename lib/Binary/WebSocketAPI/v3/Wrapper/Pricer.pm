package Binary::WebSocketAPI::v3::Wrapper::Pricer;

use strict;
use warnings;

no indirect;

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
use List::Util qw(min none);
use Format::Util::Numbers qw/formatnumber roundcommon financialrounding/;

use Future::Mojo          ();
use Future::Utils         ();
use Variable::Disposition ();

use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Wrapper::Streamer;
use Binary::WebSocketAPI::v3::PricingSubscription;

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

my $json               = JSON::MaybeXS->new->allow_blessed;
my %pricer_cmd_handler = (
    price => \&process_ask_event,
    bid   => \&process_bid_event,
);

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
                $req_storage->{uuid} = _pricing_channel_for_ask($c, $req_storage->{args}, $cache);
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

    $copy_args->{skip_streaming} = 1;    # only for proposal_array: do not create redis subscription, we need only uuid stored in stash

    my $uuid = _pricing_channel_for_ask($c, $copy_args, {});
    unless ($uuid) {
        my $error = $c->new_error('proposal_array', 'AlreadySubscribed', $c->l('You are already subscribed to [_1].', 'proposal_array'));
        $c->send({json => $error}, $req_storage);
        return;
    }

    if ($req_storage->{args}{subscribe}) {    # store data in stash if it is a subscription
        my $proposal_array_subscriptions = $c->stash('proposal_array_subscriptions') // {};
        $proposal_array_subscriptions->{$uuid} = {
            args      => $req_storage->{args},
            proposals => {},
            seq       => []};
        $c->stash(proposal_array_subscriptions => $proposal_array_subscriptions);
        my $position = 0;
        for my $barrier (@$barrier_chunks) {
            $barriers_order->{_make_barrier_key($barrier->[0])} = $position++;
        }
    }

    my $create_price_channel = sub {
        my ($c, $rpc_response, $req_storage) = @_;
        my $cache = {
            proposal_array_subscription => $uuid,    # does not matters if there will not be any subscription
        };

        # Apply contract parameters - we will use them for Price::Calculator calls to determine
        # the actual price from the theo_probability value the pricers return
        for my $contract_type (keys %{$rpc_response->{proposals}}) {
            for my $barrier (@{$rpc_response->{proposals}{$contract_type}}) {
                my $barrier_key = _make_barrier_key($barrier->{error} ? $barrier->{error}->{details} : $barrier);
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

        $req_storage->{uuid} = _pricing_channel_for_ask($c, $req_storage->{args}, $cache);
        if ($req_storage->{args}{subscribe}) {    # we are in subscr mode, so remember the sequence of streams
            my $proposal_array_subscriptions = $c->stash('proposal_array_subscriptions');
            if ($proposal_array_subscriptions->{$uuid}) {
                if ($req_storage->{uuid}) {
                    my $barriers = $req_storage->{args}{barriers}[0];
                    my $idx      = _make_barrier_key($barriers);
                    warn "unknown idx " . $idx . ", available: " . join ',', sort keys %$barriers_order unless exists $barriers_order->{$idx};
                    ${$proposal_array_subscriptions->{$uuid}{seq}}[$barriers_order->{$idx}] = $req_storage->{uuid};
                    # creating this key to be used by forget_all, undef - not to allow proposal_array message to be sent before real data received
                    $proposal_array_subscriptions->{$uuid}{proposals}{$req_storage->{uuid}} = undef;
                } else {
                    # `_pricing_channel_for_ask` does not generated uuid.
                    # it could be rare case when 2 proposal_array calls are performed in one connection
                    # and they have similar but not the same barriers, so some chunks became the same
                    # in this case `proposal_array` RPC hook `response` will send error message to client and will stop processing this call
                    # so subscription should be removed.
                    Binary::WebSocketAPI::v3::Wrapper::System::_forget_proposal_array($c, $uuid);
                    delete $proposal_array_subscriptions->{$uuid};
                }
                $c->stash(proposal_array_subscriptions => $proposal_array_subscriptions);
            }
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
                            Binary::WebSocketAPI::v3::Wrapper::System::_forget_proposal_array($c, $uuid);
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
        Binary::WebSocketAPI::v3::Wrapper::Streamer::transaction_channel($c, 'subscribe', $c->stash('account_id'), 'poc', $args)
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
    if ($last_contracts->{$args->{contract_id}}) {
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
    } else {
        return $empty_answer;
    }

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
                and not $contract->{is_expired}
                and not $contract->{is_sold}
                and not delete $contract->{dont_stream})
            {
                # short_code contract_id currency is_sold sell_time are passed to pricer daemon and
                # are used to to identify redis channel and as arguments to get_bid rpc call
                # transaction_ids purchase_time buy_price should be stored and will be added to
                # every get_bid results and sent to client while streaming
                my $cache = {map { $_ => $contract->{$_} }
                        qw(account_id shortcode contract_id currency buy_price sell_price sell_time purchase_time is_sold transaction_ids longcode)};

                if (not $uuid = pricing_channel_for_bid($c, $args, $cache)) {
                    my $error =
                        $c->new_error('proposal_open_contract', 'AlreadySubscribed',
                        $c->l('You are already subscribed to [_1].', 'proposal_open_contract'));
                    $c->send({json => $error}, $req_storage);
                    return;
                } else {
                    # subscribe to transaction channel as when contract is manually sold we need to cancel streaming
                    Binary::WebSocketAPI::v3::Wrapper::Streamer::transaction_channel(
                        $c, 'subscribe', delete $contract->{account_id},    # should not go to client
                        $uuid, $args, $contract->{contract_id});
                }
            }
            my $result = {$uuid ? (id => $uuid) : (), %{$contract}};
            delete $result->{rpc_time};
            delete $result->{account_id};
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
    foreach my $k (sort keys %$copy) {
        push @arr, ($k, $copy->{$k});
    }
    return 'PRICER_KEYS::' . Encode::encode_utf8($json->encode([map { !defined($_) ? $_ : ref($_) ? $_ : "$_" } @arr]));
}

sub _pricing_channel_for_ask {
    my ($c, $args, $cache) = @_;
    my $price_daemon_cmd = 'price';

    my %args_hash = %{$args};

    if ($args_hash{basis} and $args_hash{basis} ne 'multiplier' and $args_hash{contract_type} !~ /SPREAD$/) {
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
    my $subchannel    = $args->{amount};

    my $skip = Binary::WebSocketAPI::v3::Wrapper::Streamer::_skip_streaming($args);

    # uuid is needed regardless of whether its subscription or not
    return _create_pricer_channel($c, $args, $redis_channel, $subchannel, $price_daemon_cmd, $cache, $skip);
}

sub pricing_channel_for_bid {
    my ($c, $args, $cache) = @_;
    my $price_daemon_cmd = 'bid';

    my %hash;
    # get_bid RPC call requires 'short_code' param, not 'shortcode'
    @hash{qw(short_code contract_id currency sell_time)} = delete @{$cache}{qw(shortcode contract_id currency sell_time)};
    $hash{is_sold} = $cache->{is_sold} + 0;
    $hash{language}         = $c->stash('language') || 'EN';
    $hash{price_daemon_cmd} = $price_daemon_cmd;
    $hash{landing_company}  = $c->landing_company_name;
    # use residence when available, fall back to IP country
    $hash{country_code} = $c->stash('residence') || $c->stash('country_code');
    my $redis_channel = _serialized_args(\%hash);

    %hash = map { $_ =~ /passthrough/ ? () : ($_ => $args->{$_}) } keys %$args;
    $hash{account_id}     = delete $cache->{account_id};
    $hash{transaction_id} = $cache->{transaction_ids}->{buy};    # transaction is going to be stored
    my $subchannel = _serialized_args(\%hash);

    return _create_pricer_channel($c, $args, $redis_channel, $subchannel, $price_daemon_cmd, $cache);
}

sub _create_pricer_channel {
    my ($c, $args, $redis_channel, $subchannel, $price_daemon_cmd, $cache, $skip_redis_subscr) = @_;
    my $pricing_channel = $c->stash('pricing_channel') || {};

    # channel already generated
    if (exists $pricing_channel->{$redis_channel} and exists $pricing_channel->{$redis_channel}->{$subchannel}) {
        return $pricing_channel->{$redis_channel}->{$subchannel}->{uuid}
            if not(exists $args->{subscribe} and $args->{subscribe} == 1)
            and exists $pricing_channel->{$redis_channel}->{$subchannel}->{uuid};
        return;
    }

    my $uuid = Binary::WebSocketAPI::v3::Wrapper::Streamer::_generate_uuid_string();

    my $channel_not_subscribed = sub {
        return 1 if not exists $pricing_channel->{$redis_channel};
        my @all_uuids = map { $_->{uuid} } values %{$pricing_channel->{$redis_channel}};
        return none { exists $pricing_channel->{uuid}{$_}{subscription} } @all_uuids;
    };
    # subscribe if it is not already subscribed
    if (    exists $args->{subscribe}
        and $args->{subscribe} == 1
        and $channel_not_subscribed->()
        and not $skip_redis_subscr)
    {
        $pricing_channel->{uuid}{$uuid}{subscription} =
            $c->pricing_subscriptions($redis_channel)->subscribe($c);
    }

    # TODO I think here should be refactored. here redis_channel exists in this hash doesn't mean this channel already subscribed.
    $pricing_channel->{$redis_channel}->{$subchannel}->{uuid}          = $uuid;
    $pricing_channel->{$redis_channel}->{$subchannel}->{args}          = $args;
    $pricing_channel->{$redis_channel}->{$subchannel}->{cache}         = $cache;
    $pricing_channel->{uuid}->{$uuid}->{redis_channel}                 = $redis_channel;
    $pricing_channel->{uuid}->{$uuid}->{subchannel}                    = $subchannel;
    $pricing_channel->{uuid}->{$uuid}->{price_daemon_cmd}              = $price_daemon_cmd;
    $pricing_channel->{uuid}->{$uuid}->{args}                          = $args;               # for buy rpc call
    $pricing_channel->{uuid}->{$uuid}->{cache}                         = $cache;
    $pricing_channel->{price_daemon_cmd}->{$price_daemon_cmd}->{$uuid} = 1;                   # for forget_all
    $c->stash('pricing_channel' => $pricing_channel);
    return $uuid;
}

sub process_pricing_events {
    my ($c, $message, $channel_name) = @_;

    Binary::WebSocketAPI::v3::Wrapper::System::_forget_all_pricing_subscriptions($c, 'proposal') unless $c->tx;
    return if not $message or not $c->tx;
    my $pricing_channel = $c->stash('pricing_channel');
    return if not $pricing_channel or not $pricing_channel->{$channel_name};

    my $response = $json->decode(Encode::decode_utf8($message));
    my $price_daemon_cmd = delete $response->{price_daemon_cmd} // '';

    my $pricing_channel_updated = undef;
    if (exists $pricer_cmd_handler{$price_daemon_cmd}) {
        $pricing_channel_updated = $pricer_cmd_handler{$price_daemon_cmd}->($c, $response, $channel_name, $pricing_channel);
    } else {
        warn "Unknown command received from pricer daemon : " . ($price_daemon_cmd // 'undef');
    }

    $c->stash(pricing_channel => $pricing_channel) if $pricing_channel_updated;

    return;
}

sub process_bid_event {
    my ($c, $response, $redis_channel, $pricing_channel) = @_;
    my $type = 'proposal_open_contract';

    my @stash_items = grep { ref($_) eq 'HASH' } values %{$pricing_channel->{$redis_channel}};
    for my $stash_data (@stash_items) {
        my $results;
        unless ($results = _get_validation_for_type($type)->($c, $response, $stash_data)) {
            my $passed_fields = $stash_data->{cache};

            $response->{id}              = $stash_data->{uuid};
            $response->{transaction_ids} = $passed_fields->{transaction_ids};
            $response->{buy_price}       = $passed_fields->{buy_price};
            $response->{purchase_time}   = $passed_fields->{purchase_time};
            $response->{is_sold}         = $passed_fields->{is_sold};
            if ($response->{buy_price} and $response->{bid_price} and $response->{currency}) {
                $response->{profit} = formatnumber('price', $response->{currency}, $response->{bid_price} - $response->{buy_price});
                $response->{profit_percentage} = roundcommon(0.01, $response->{profit} / $response->{buy_price} * 100);
            }
            Binary::WebSocketAPI::v3::Wrapper::System::forget_one($c, $stash_data->{uuid})
                if $response->{is_sold};
            $response->{longcode} = $passed_fields->{longcode};

            $response->{contract_id} = $stash_data->{args}->{contract_id} if exists $stash_data->{args}->{contract_id};
            $results = {
                msg_type     => $type,
                $type        => $response,
                subscription => {id => $stash_data->{uuid}},
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

        $c->send({json => $results}, {args => $stash_data->{args}});
    }
    return;
}

sub process_proposal_array_event {
    my ($c, $response, $redis_channel, $pricing_channel) = @_;

    my $type                    = 'proposal';
    my $pricing_channel_updated = undef;

    unless ($c->stash('proposal_array_collector_running')) {
        $c->stash('proposal_array_collector_running' => 1);
        # start 1 sec proposal_array sender if not started yet
        # see lib/Binary/WebSocketAPI/Plugins/Helpers.pm line ~ 178
        $c->proposal_array_collector;
    }

    for my $stash_data_key (keys %{$pricing_channel->{$redis_channel}}) {
        my $stash_data = $pricing_channel->{$redis_channel}{$stash_data_key};
        unless (ref($stash_data) eq 'HASH') {
            warn __PACKAGE__ . " process_proposal_array_event: HASH not found as redis_channel data: " . $json->encode($stash_data);
            delete $pricing_channel->{$redis_channel}{$stash_data_key};
            $pricing_channel_updated = 1;
            next;
        }
        $stash_data->{cache}{contract_parameters}{currency} ||= $stash_data->{args}{currency};
        my %proposals;
        for my $contract_type (keys %{$response->{proposals}}) {
            $proposals{$contract_type} = (my $barriers = []);
            for my $price (@{$response->{proposals}{$contract_type}}) {
                my $result = try {
                    if (my $invalid = _get_validation_for_type($type)->($c, $response, $stash_data, {args => 'contract_type'})) {
                        warn __PACKAGE__ . " process_proposal_array_event: _get_validation_for_type failed, results: " . $json->encode($invalid);
                        return $invalid;
                    } elsif (exists $price->{error}) {
                        return $price;
                    } else {
                        my $barrier_key      = _make_barrier_key($price);
                        my $theo_probability = delete $price->{theo_probability};
                        delete $price->{supplied_barrier};
                        delete $price->{supplied_barrier2};
                        my $stashed_contract_parameters = $stash_data->{cache}{$contract_type}{$barrier_key};
                        $stashed_contract_parameters->{contract_parameters}{currency} ||= $stash_data->{args}{currency};
                        $stashed_contract_parameters->{contract_parameters}{$stashed_contract_parameters->{contract_parameters}{amount_type}} =
                            $stashed_contract_parameters->{contract_parameters}{amount};
                        delete $stashed_contract_parameters->{contract_parameters}{ask_price};

                        # Make sure that we don't override any of the values for next time (e.g. ask_price)
                        my $copy = {contract_parameters => {%{$stashed_contract_parameters->{contract_parameters}}}};
                        my $res = _price_stream_results_adjustment($c, $stash_data->{args}, $copy, $price, $theo_probability);
                        $res->{longcode} = $c->l($res->{longcode}) if $res->{longcode};
                        return $res;
                    }
                }
                catch {
                    warn __PACKAGE__ . " Failed to apply price - $_ - with a price struc containing " . Dumper($price);
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
        if (my $subscription_key = $stash_data->{cache}{proposal_array_subscription}) {
            my $proposal_array_subscriptions = $c->stash('proposal_array_subscriptions') // {};
            if (ref $proposal_array_subscriptions->{$subscription_key} eq 'HASH') {
                $proposal_array_subscriptions->{$subscription_key}{proposals}{$stash_data->{uuid}} = \%proposals;
                $c->stash(proposal_array_subscriptions => $proposal_array_subscriptions);
            } else {
                Binary::WebSocketAPI::v3::Wrapper::System::forget_one($c, $stash_data->{uuid});
            }
        }
    }
    return $pricing_channel_updated;
}

sub process_ask_event {
    my ($c, $response, $redis_channel, $pricing_channel) = @_;
    my $type                    = 'proposal';
    my $pricing_channel_updated = undef;

    return process_proposal_array_event($c, $response, $redis_channel, $pricing_channel) if exists $response->{proposals};

    my $theo_probability = delete $response->{theo_probability};
    for my $stash_data_key (keys %{$pricing_channel->{$redis_channel}}) {
        my $stash_data = $pricing_channel->{$redis_channel}{$stash_data_key};
        unless (ref($stash_data) eq 'HASH') {
            warn __PACKAGE__ . " process_ask_event: HASH not found as redis_channel data: " . $json->encode($stash_data);
            delete $pricing_channel->{$redis_channel}{$stash_data_key};
            $pricing_channel_updated = 1;
            next;
        }
        my $results;
        if ($results = _get_validation_for_type($type)->($c, $response, $stash_data, {args => 'contract_type'})) {
            stats_inc('price_adjustment.validation_for_type_failure', {tags => ['type:' . $type]});
        } else {
            $stash_data->{cache}->{contract_parameters}->{longcode} = $stash_data->{cache}->{longcode};
            my $adjusted_results =
                _price_stream_results_adjustment($c, $stash_data->{args}, $stash_data->{cache}, $response, $theo_probability);
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
                        id       => $stash_data->{uuid},
                        longcode => $c->l($stash_data->{cache}->{longcode}),
                    },
                    subscription => {id => $stash_data->{uuid}},
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
        $c->send({json => $results}, {args => $stash_data->{args}});
    }
    return $pricing_channel_updated;
}

sub _price_stream_results_adjustment {
    my ($c, undef, $cache, $results, $resp_theo_probability) = @_;

    my $contract_parameters = $cache->{contract_parameters};

    if ($contract_parameters->{non_binary_results_adjustment}) {
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

        return $results;
    }

    # log the instances when pricing server doesn't return theo probability
    unless (defined $resp_theo_probability) {
        warn 'missing theo probability from pricer. Contract parameter dump '
            . $json->encode($contract_parameters)
            . ', pricer response: '
            . $json->encode($results);
        stats_inc('price_adjustment.missing_theo_probability');
    }

    my $t = [gettimeofday];
    # overrides the theo_probability which take the most calculation time.
    # theo_probability is a calculated value (CV), overwrite it with CV object.
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
    $cache->{payout} = $price_calculator->payout;
    if (my $error = $price_calculator->validate_price) {
        my $error_map = {
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
                return ('Minimum stake of [_1] and maximum payout of [_2]. Current payout is [_3].', $details->[0], $details->[1], $details->[2]);
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

#
# we're finishing POC stream on contract is sold (called from _close_proposal_open_contract_stream in Streamer.pm)
#
sub send_proposal_open_contract_last_time {
    my ($c, $args, $contract_id, $stash_data) = @_;
    Binary::WebSocketAPI::v3::Wrapper::System::forget_one($c, $args->{uuid});

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
                }
                return {
                    proposal_open_contract => $rpc_response->{$contract_id} || {},
                    msg_type => 'proposal_open_contract',
                    subscription => {id => $args->{uuid}}};
            }
        });
    return;
}

sub _create_error_message {
    my ($c, $type, $response, $stash_data) = @_;
    my ($err_code, $err_message, $err_details);

    Binary::WebSocketAPI::v3::Wrapper::System::forget_one($c, $stash_data->{cache}{proposal_array_subscription} || $stash_data->{uuid});

    if ($response->{error}) {
        $err_code    = $response->{error}->{code};
        $err_details = $response->{error}->{details};
        # in pricer_dameon everything happens in Eng to maximize the collisions.
        $err_message = $c->l($response->{error}->{message_to_client});
    } else {
        $err_code    = 'InternalServerError';
        $err_message = 'Internal server error';
        warn "Pricer '$type' stream event processing error: " . ($response ? "stash data missed" : "empty response from pricer daemon") . "\n";
    }
    my $err = $c->new_error($type, $err_code, $err_message);
    $err->{error}->{details} = $err_details if $err_details;

    return $err;
}

sub _invalid_response_or_stash_data {
    my ($c, $response, $stash_data, $additional_params_to_check) = @_;

    my $err =
          !$response
        || $response->{error}
        || !$stash_data->{args}
        || !$stash_data->{uuid}
        || !$stash_data->{cache};

    if (ref $additional_params_to_check eq 'HASH') {
        for my $key (sort keys %$additional_params_to_check) {
            $err ||= !$stash_data->{$key}->{$additional_params_to_check->{$key}};
        }
    }

    return $err ? sub { my $type = shift; return _create_error_message($c, $type, $response, $stash_data) } : sub { };
}

sub _get_validation_for_type {
    my $type = shift;
    return sub {
        return _invalid_response_or_stash_data(@_)->($type);
        }
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

sub _make_barrier_key {
    my ($barrier) = @_;
    return $barrier unless ref $barrier;
    # In proposal_array we use barriers to order proposals[] array responses.
    # Even if it's a relative barrier, for that Contract->handle_batch_contract also sends the supplied barrier back.
    if (exists $barrier->{supplied_barrier}) {
        return join ':', $barrier->{supplied_barrier}, $barrier->{supplied_barrier2} // ();
    }
    return join ':', $barrier->{barrier} // (), $barrier->{barrier2} // ();
}

1;
