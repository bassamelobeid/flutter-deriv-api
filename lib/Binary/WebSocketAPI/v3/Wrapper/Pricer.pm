package Binary::WebSocketAPI::v3::Wrapper::Pricer;

use strict;
use warnings;
use JSON;
use Data::Dumper;
use Format::Util::Numbers qw(roundnear);
use Binary::WebSocketAPI::v3::Wrapper::System;
use Mojo::Redis::Processor;
use JSON::XS qw(encode_json decode_json);
use Time::HiRes qw(gettimeofday tv_interval);
use Binary::WebSocketAPI::v3::Wrapper::Streamer;
use Math::Util::CalculatedValue::Validatable;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);
use Format::Util::Numbers qw(to_monetary_number_format);
use Price::Calculator;
use Clone::PP qw(clone);

my %pricer_cmd_handler = (
    price => \&process_ask_event,
    bid   => \&process_bid_event,
);

sub proposal {
    my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};
    $c->call_rpc({
            args        => $args,
            method      => 'send_ask',
            msg_type    => 'proposal',
            call_params => {
                language              => $c->stash('language'),
                app_markup_percentage => $c->stash('app_markup_percentage'),
                landing_company       => $c->landing_company_name,
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

                $api_response->{passthrough} = $req_storage->{args}->{passthrough};
                if (my $uuid = $req_storage->{uuid}) {
                    $api_response->{proposal}->{id} = $uuid;
                } else {
                    $api_response = $c->new_error('proposal', 'AlreadySubscribed', $c->l('You are already subscribed to proposal.'));
                }
                return $api_response;
            },
        });
    return;
}

sub proposal_array {
    my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};
    $c->call_rpc({
            args        => $args,
            method      => 'send_multiple_ask',
            msg_type    => 'proposal_array',
            call_params => {
                language              => $c->stash('language'),
                app_markup_percentage => $c->stash('app_markup_percentage'),
                landing_company       => $c->stash('landing_company_name'),
            },
            success => sub {
                my ($c, $rpc_response, $req_storage) = @_;

                my $caches = [];
                for my $response (@{$rpc_response->{proposals}}) {
                    my $cache;
                    if (exists($response->{error})) {
                        $cache = {
                            error                 => 1,
                            app_markup_percentage => $c->stash('app_markup_percentage'),
                        };
                    } else {
                        $cache = {
                            payout              => $rpc_response->{payout},
                            longcode            => $response->{longcode},
                            contract_parameters => delete $response->{contract_parameters}};
                        $cache->{contract_parameters}->{app_markup_percentage} = $c->stash('app_markup_percentage');
                    }
                    push @$caches, $cache;
                }
                $req_storage->{uuid} = _pricing_channel_for_ask($c, $req_storage->{args}, $caches);
            },
            response => sub {
                my ($rpc_response, $api_response, $req_storage) = @_;
                return $api_response if $rpc_response->{error};

                for my $proposal (@{$api_response->{proposal_array}{proposals}}) {
                    delete $proposal->{error}{continue_price_stream} if exists $proposal->{error};
                }

                $api_response->{passthrough} = $req_storage->{args}->{passthrough};
                if (my $uuid = $req_storage->{uuid}) {
                    $api_response->{proposal_array}->{id} = $uuid;
                } else {
                    $api_response = $c->new_error('proposal_array', 'AlreadySubscribed', $c->l('You are already subscribed to proposal array.'));
                }
                return $api_response;
            },
        });
    return;
}

sub proposal_open_contract {
    my ($c, $response, $req_storage) = @_;

    my $args         = $req_storage->{args};
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
            # responce contains data or rpc error - so no need to retry rpc call
            my $valid_response = %{$response->{proposal_open_contract}} || $rpc_response->{error};

            # empty response and having some tries
            if (!$valid_response && --$retries) {
                # we still have to retry, so sleep a second and perform rpc call again
                Mojo::IOLoop->timer(1, $call_sub);
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
        if (exists $contract->{error}) {
            my $error =
                $c->new_error('proposal_open_contract', 'ContractValidationError', $c->l($contract->{error}->{message_to_client}));
            $c->send({json => $error}, $req_storage);
        } elsif (not exists $contract->{shortcode}) {
            my %copy_req = %$req_storage;
            delete @copy_req{qw(in_validator out_validator)};
            $copy_req{loginid} = $c->stash('loginid') if $c->stash('loginid');
            warn "undef shortcode req_storage " . Dumper(\%copy_req);
            my $error =
                $c->new_error('proposal_open_contract', 'GetProposalFailure', $c->l('Sorry, an error occurred while processing your request.'));
            $c->send({json => $error}, $req_storage);
        } else {
            my $uuid;

            if (    exists $args->{subscribe}
                and $args->{subscribe} eq '1'
                and not $contract->{is_expired}
                and not $contract->{is_sold})
            {
                # short_code contract_id currency is_sold sell_time are passed to pricer daemon and
                # are used to to identify redis channel and as arguments to get_bid rpc call
                # transaction_ids purchase_time buy_price should be stored and will be added to
                # every get_bid results and sent to client while streaming
                my $cache = {map { $_ => $contract->{$_} }
                        qw(account_id shortcode contract_id currency buy_price sell_price sell_time purchase_time is_sold transaction_ids longcode)};

                if (not $uuid = _pricing_channel_for_bid($c, $args, $cache)) {
                    my $error =
                        $c->new_error('proposal_open_contract', 'AlreadySubscribed', $c->l('You are already subscribed to proposal_open_contract.'));
                    $c->send({json => $error}, $req_storage);
                    next;
                } else {
                    # subscribe to transaction channel as when contract is manually sold we need to cancel streaming
                    Binary::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel(
                        $c, 'subscribe', delete $contract->{account_id},    # should not go to client
                        $uuid, {contract_id => $contract->{contract_id}});
                }
            }
            my $result = {$uuid ? (id => $uuid) : (), %{$contract}};
            delete $result->{rpc_time};
            $c->send({
                    json => {
                        msg_type               => 'proposal_open_contract',
                        proposal_open_contract => {%$result}
                    },
                },
                $req_storage
            );
        }
    }
    return;
}

sub _serialized_args {
    my $h    = shift;
    my $copy = {%$h};
    my @a    = ();
    # We want to handle similar contracts together, so we do this and sort by
    # key in the price_queue.pl daemon
    push @a, ('short_code', delete $copy->{short_code}) if exists $copy->{short_code};
    foreach my $k (sort keys %$copy) {
        push @a, ($k, $copy->{$k});
    }
    return 'PRICER_KEYS::' . encode_json(\@a);
}

sub _pricing_channel_for_ask {
    my ($c, $args, $cache) = @_;
    my $price_daemon_cmd = 'price';

    my %args_hash = %{$args};

    if ($args_hash{basis}) {
        $args_hash{amount} = 1000;
        $args_hash{basis}  = 'payout';
    }

    delete $args_hash{passthrough};

    $args_hash{language}               = $c->stash('language') || 'EN';
    $args_hash{price_daemon_cmd}       = $price_daemon_cmd;
    $args_hash{landing_company}        = $c->landing_company_name;
    $args_hash{skips_price_validation} = 1;
    my $redis_channel = _serialized_args(\%args_hash);
    my $subchannel = $args->{amount_per_point} // $args->{amount};

    my $skip = Binary::WebSocketAPI::v3::Wrapper::Streamer::_skip_streaming($args);

    # uuid is needed regardless of whether its subscription or not
    return _create_pricer_channel($c, $args, $redis_channel, $subchannel, $price_daemon_cmd, $cache, $skip);
}

sub _pricing_channel_for_bid {
    my ($c, $args, $cache) = @_;
    my $price_daemon_cmd = 'bid';

    my %hash;
    # get_bid RPC call requires 'short_code' param, not 'shortcode'
    @hash{qw(short_code contract_id currency sell_time)} = delete @{$cache}{qw(shortcode contract_id currency sell_time)};
    $hash{is_sold} = $cache->{is_sold} + 0;
    $hash{language}         = $c->stash('language') || 'EN';
    $hash{price_daemon_cmd} = $price_daemon_cmd;
    $hash{landing_company}  = $c->landing_company_name;
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

    # already subscribed
    if (exists $pricing_channel->{$redis_channel} and exists $pricing_channel->{$redis_channel}->{$subchannel}) {
        return $pricing_channel->{$redis_channel}->{$subchannel}->{uuid}
            if not(exists $args->{subscribe} and $args->{subscribe} == 1)
            and exists $pricing_channel->{$redis_channel}->{$subchannel}->{uuid};
        return;
    }

    my $uuid = &Binary::WebSocketAPI::v3::Wrapper::Streamer::_generate_uuid_string();

    # subscribe if it is not already subscribed
    if (    exists $args->{subscribe}
        and $args->{subscribe} == 1
        and not exists $pricing_channel->{$redis_channel}
        and not $skip_redis_subscr)
    {
        $c->redis_pricer->set($redis_channel, 1);
        $c->stash('redis_pricer')->subscribe([$redis_channel], sub { });

        my $count = $c->stash->{redis_pricer_count} || 0;

        $c->stash->{redis_pricer_count} = ++$count;

        $c->app->log->warn("[$$],"
                . ($c->stash->{source}       || '') . ","
                . ($c->stash->{client_ip}    || '') . ","
                . ($c->stash->{country_code} || '') . ","
                . ($c->stash->{loginid}      || '')
                . ",$count")
            if -f '/etc/rmg/debug';
    }

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

    return if not $message or not $c->tx;
    my $pricing_channel = $c->stash('pricing_channel');
    return if not $pricing_channel or not $pricing_channel->{$channel_name};

    my $response = decode_json($message);
    my $price_daemon_cmd = delete $response->{price_daemon_cmd} // '';

    if (exists $pricer_cmd_handler{$price_daemon_cmd}) {
        $pricer_cmd_handler{$price_daemon_cmd}->($c, $response, $channel_name, $pricing_channel);
    } else {
        warn "Unknown command received from pricer daemon : " . ($price_daemon_cmd // 'undef');
    }

    return;
}

sub process_bid_event {
    my ($c, $response, $redis_channel, $pricing_channel) = @_;
    my $type = 'proposal_open_contract';

    for my $stash_data (values %{$pricing_channel->{$redis_channel}}) {
        my $results;
        unless ($results = _get_validation_for_type($type)->($c, $response, $stash_data)) {
            my $passed_fields = $stash_data->{cache};
            $response->{id}              = $stash_data->{uuid};
            $response->{transaction_ids} = $passed_fields->{transaction_ids};
            $response->{buy_price}       = $passed_fields->{buy_price};
            $response->{purchase_time}   = $passed_fields->{purchase_time};
            $response->{is_sold}         = $passed_fields->{is_sold};
            $response->{longcode}        = $passed_fields->{longcode};
            $results                     = {
                msg_type => $type,
                $type    => $response
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

sub process_ask_event {
    my ($c, $response, $redis_channel, $pricing_channel) = @_;

    if (exists($response->{proposals})) {    #proposal_array
        _process_ask_proposal_array_event(@_);
    } else {                                 #proposal
        _process_ask_proposal_event(@_);
    }
    return;
}

sub _process_ask_proposal_event {
    my ($c, $response, $redis_channel, $pricing_channel) = @_;
    my $type = 'proposal';

    my $theo_probability = delete $response->{theo_probability};
    foreach my $stash_data (values %{$pricing_channel->{$redis_channel}}) {
        my $results;

        unless ($results = _get_validation_for_type($type)->($c, $response, $stash_data, {args => 'contract_type'})) {
            $stash_data->{cache}->{contract_parameters}->{longcode} = $stash_data->{cache}->{longcode};
            my $adjusted_results =
                _price_stream_results_adjustment($c, $stash_data->{args}, $stash_data->{cache}, $response, $theo_probability);
            if (my $ref = $adjusted_results->{error}) {
                my $err = $c->new_error($type, $ref->{code}, $ref->{message_to_client});
                $err->{error}->{details} = $ref->{details} if exists $ref->{details};
                $results = $err;
            } else {
                $results = {
                    msg_type => $type,
                    $type    => {
                        %$adjusted_results,
                        id       => $stash_data->{uuid},
                        longcode => $stash_data->{cache}->{longcode},
                    },
                };
            }
        }
        if ($c->stash('debug')) {
            $results->{debug} = {
                time   => $results->{$type}->{rpc_time},
                method => $type,
            };
        }
        delete @{$results->{$type}}{qw(contract_parameters rpc_time)};
        $c->send({json => $results}, {args => $stash_data->{args}});
    }
    return;
}

sub _process_ask_proposal_array_event {
    my ($c, $response, $redis_channel, $pricing_channel) = @_;
    my $type      = 'proposal_array';
    my $responses = $response->{proposals};
    foreach my $stash_data (values %{$pricing_channel->{$redis_channel}}) {
        my $caches = $stash_data->{cache};
        my @results;
        for my $i (0 .. $#$responses) {
            my $response         = clone($responses->[$i]);
            my $cache            = $caches->[$i];
            my $theo_probability = delete $response->{theo_probability};
            my $results;

            unless ($results = _get_validation_for_type($type)->($c, $response, $stash_data, {args => 'contract_type'})) {
                if (exists($cache->{error})) {
                    # There is error when we ask proposal array
                    # but now the error is gone
                    # so we set cache as the first correct value
                    $cache->{longcode}                                   = $response->{longcode};
                    $cache->{contract_parameters}                        = $response->{contract_parameters};
                    $cache->{contract_parameters}{app_markup_percentage} = delete $cache->{app_markup_percentage};
                    delete $cache->{error};
                }
                $cache->{contract_parameters}->{longcode} = $cache->{longcode};
                my $adjusted_results = _price_stream_results_adjustment($c, $stash_data->{args}, $cache, $response, $theo_probability);
                if (my $ref = $adjusted_results->{error}) {
                    my $err = $c->new_error($type, $ref->{code}, $ref->{message_to_client});
                    $err->{error}->{details} = $ref->{details} if exists $ref->{details};
                    my $barriers = $stash_data->{args}{barriers}[$i];
                    @{$err->{error}{details}}{keys %$barriers} = values %$barriers;
                    $results = $err;
                } else {
                    $results = {
                        %$adjusted_results,
                        longcode => $cache->{longcode},
                    };
                }
            }
            delete @{$results}{qw(msg_type contract_parameters)};
            push @results, $results;
        }

        my $send_result = {
            msg_type => $type,
            $type    => {
                proposals => \@results,
                id        => $stash_data->{uuid},
            }};
        if ($c->stash('debug')) {
            $send_result->{debug} = {
                time   => $response->{rpc_time},
                method => $type,
            };
        }
        $c->send({json => $send_result}, {args => $stash_data->{args}});
    }
    return;
}

sub _price_stream_results_adjustment {
    my $c                     = shift;
    my $orig_args             = shift;
    my $cache                 = shift;
    my $results               = shift;
    my $resp_theo_probability = shift;

    my $contract_parameters = $cache->{contract_parameters};
    # skips for spreads
    $_ eq $orig_args->{contract_type} and return $results for qw(SPREADU SPREADD);

    # log the instances when pricing server doesn't return theo probability
    unless (defined $resp_theo_probability) {
        warn 'missing theo probability from pricer. Contract parameter dump ' . Data::Dumper->Dumper($contract_parameters);
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
            zero_stake             => sub { "Invalid stake" },
            payout_too_many_places => sub { 'Payout may not have more than two decimal places.' },
            stake_same_as_payout   => sub { 'This contract offers no return.' },
            stake_outside_range    => sub {
                my ($details) = @_;
                return (
                    'Minimum stake of [_1] and maximum payout of [_2]',
                    to_monetary_number_format($details->[0]),
                    to_monetary_number_format($details->[1]));
            },
            payout_outside_range => sub {
                my ($details) = @_;
                return (
                    'Minimum stake of [_1] and maximum payout of [_2]',
                    to_monetary_number_format($details->[0]),
                    to_monetary_number_format($details->[1]));
            },
        };
        return {
            error => {
                message_to_client => $c->l($error_map->{$error->{error_code}}->($error->{error_details} || [])),
                code              => 'ContractBuyValidationError',
                details           => {
                    longcode      => $contract_parameters->{longcode},
                    display_value => $price_calculator->ask_price,
                    payout        => $price_calculator->payout,
                },
            }};
    }

    $results->{ask_price} = $results->{display_value} = $price_calculator->ask_price;
    $results->{payout} = $price_calculator->payout;
    map { $results->{$_} .= '' } qw(ask_price display_value payout);
    stats_timing('price_adjustment.timing', 1000 * tv_interval($t));

    return $results;
}

sub send_proposal_open_contract_last_time {
    # last message (contract is sold) of proposal_open_contract stream could not be done from pricer
    # because it should be performed with other parameters
    my ($c, $args) = @_;
    my $uuid = $args->{uuid};

    my $pricing_channel = $c->stash('pricing_channel');
    return if not $pricing_channel or not $pricing_channel->{uuid}->{$uuid};
    my $cache = $pricing_channel->{uuid}->{$uuid}->{cache};

    my $forget_subscr_sub = sub {
        my ($c, $rpc_response) = @_;
        # cancel proposal open contract streaming which will cancel transaction subscription also
        Binary::WebSocketAPI::v3::Wrapper::System::forget_one($c, $uuid);
    };

    $c->call_rpc({
            args        => $pricing_channel->{uuid}->{$uuid}->{args},
            method      => 'get_bid',
            msg_type    => 'proposal_open_contract',
            call_params => {
                short_code  => $args->{short_code},
                contract_id => $args->{financial_market_bet_id},
                currency    => $args->{currency_code},
                sell_time   => $args->{sell_time},
                is_sold     => 1,
            },
            response => sub {
                my ($rpc_response, $api_response, $req_storage) = @_;

                return $api_response if $rpc_response->{error};

                $api_response->{proposal_open_contract}->{buy_price}               = $cache->{buy_price};
                $api_response->{proposal_open_contract}->{purchase_time}           = $cache->{purchase_time};
                $api_response->{proposal_open_contract}->{transaction_ids}         = $cache->{transaction_ids};
                $api_response->{proposal_open_contract}->{transaction_ids}->{sell} = $args->{id};
                $api_response->{proposal_open_contract}->{sell_price}              = sprintf('%.2f', $args->{amount});
                $api_response->{proposal_open_contract}->{sell_time}               = $args->{sell_time};
                $api_response->{proposal_open_contract}->{is_sold}                 = 1;

                return $api_response;
            },
            success => $forget_subscr_sub,
            error   => $forget_subscr_sub,
        });
    return;
}

sub _create_error_message {
    my ($c, $type, $response, $stash_data) = @_;
    my ($err_code, $err_message, $err_details);

    my $error = $response->{error} || {};
    if (not($error->{continue_price_stream}) and $stash_data->{uuid}) {
        Binary::WebSocketAPI::v3::Wrapper::System::forget_one($c, $stash_data->{uuid});
    }

    if ($response->{error}) {
        $err_code    = $response->{error}->{code};
        $err_details = $response->{error}->{details};
        # in pricer_dameon everything happens in Eng to maximize the collisions. If translations has params it will come as message_to_client_array.
        # eitherway it need l10n here.
        if ($response->{error}->{message_to_client_array}) {
            $err_message = $c->l(@{$response->{error}->{message_to_client_array}});
            warn "Had both string error and error with parameters for $type - " . $response->{error}->{message_to_client}
                if exists $response->{error}->{message_to_client};
        } else {
            $err_message = $c->l($response->{error}->{message_to_client});
        }
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

1;
