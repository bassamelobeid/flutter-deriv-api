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
                    longcode            => $rpc_response->{longcode},
                    contract_parameters => delete $rpc_response->{contract_parameters},
                    payout              => $rpc_response->{payout},
                    skip_basis_override => delete $rpc_response->{skip_basis_override} // 0,
                    skip_streaming      => delete $rpc_response->{skip_streaming} // 0,
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

    my $args         = $req_storage->{args};
    my $empty_answer = {
        msg_type               => 'proposal_open_contract',
        proposal_open_contract => {}};

    if ($args->{subscribe} && !$args->{contract_id}) {
        ### we can catch buy only if subscribed on transaction stream
        my $uuid;
        $uuid = Binary::WebSocketAPI::v3::Wrapper::Transaction::transaction_channel($c, 'subscribe', $c->stash('account_id'), 'buy', $args)
            if $c->stash('account_id');

        unless ($uuid) {
            $c->send({
                    json => $c->new_error(
                        'proposal_open_contract', 'AlreadySubscribed', $c->l('You are already subscribed to [_1].', 'proposal_open_contract'))
                },
                $req_storage
            );
            return;
        }

        $empty_answer->{subscription}->{id} = $uuid;
        ### we need stream only in subscribed workers
        # we should not overwrite the previous subscriber.
        $c->stash(proposal_open_contracts_subscribed => $args) unless $c->stash('proposal_open_contracts_subscribed');
    }

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
                my $channel_info = pricing_channel_for_proposal_open_contract($c, $args, $cache);
                if ($channel_info->{error}) {
                    my $error =
                        $c->new_error('proposal_open_contract', 'InternalError',
                        $c->l('Internal error happened when subscribing to [_1].', 'proposal_open_contract'));
                    $c->send({json => $error}, $req_storage);
                    return;
                } elsif (not $uuid = $channel_info->{uuid}) {
                    my $error =
                        $c->new_error('proposal_open_contract', 'AlreadySubscribed',
                        $c->l('You are already subscribed to [_1].', 'proposal_open_contract'));
                    $c->send({json => $error}, $req_storage);
                    return;
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
        $args->{multiplier} // '',
    );
}

sub _pricing_channel_for_proposal {
    my ($c, $args, $cache, $class) = @_;

    my $price_daemon_cmd = 'price';

    my %args_hash = %{$args};
    if (not $cache->{skip_basis_override} and $args_hash{basis} and defined $args_hash{amount}) {
        $args_hash{amount} = 1000;
        $args_hash{basis}  = 'payout';
    }

    delete $args_hash{passthrough};

    $args_hash{language}         = $c->stash('language') || 'EN';
    $args_hash{price_daemon_cmd} = $price_daemon_cmd;
    $args_hash{landing_company}  = $c->landing_company_name;
    # use residence when available, fall back to IP country
    $args_hash{country_code}           = $c->stash('residence') || $c->stash('country_code');
    $args_hash{skips_price_validation} = 1;

    my $pricer_args = _serialized_args(\%args_hash);    # name of the redis set on redis-pricer holding subchannel's as values.
    my $subchannel    = _serialize_contract_parameters($cache->{contract_parameters});   # parameters needed by price-daemon for price-adjustment.
    my $redis_channel = $pricer_args . '::' . $subchannel;                               # name of the redis channel that price-daemon publishes into.

    # uuid is needed regardless of whether its subscription or not
    return _create_pricer_channel($c, $args, $redis_channel, $subchannel, $pricer_args, $class, $cache, $cache->{skip_streaming});
}

sub pricing_channel_for_proposal_open_contract {
    my ($c, $args, $cache) = @_;

    my $contract_id     = $cache->{contract_id};
    my $landing_company = $c->landing_company_name;

    unless ($landing_company) {
        local $log->context->{longinid} = $c->stash->{loginid};
        $log->error('landing company is null when get pricing channel for proposal_open_contract');
        stats_inc('bom_websocket_api.v_3.proposal_open_contract.no_lc');
        return {error => 'LandingCompanyMissed'};
    }

    my $redis_channel = 'CONTRACT_PRICE::' . $contract_id . '_' . $landing_company;
    my $pricer_args   = _serialized_args({
        contract_id      => $contract_id,
        landing_company  => $landing_company,
        price_daemon_cmd => 'bid',
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
