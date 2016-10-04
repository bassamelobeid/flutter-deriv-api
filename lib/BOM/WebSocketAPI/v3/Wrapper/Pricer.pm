package BOM::WebSocketAPI::v3::Wrapper::Pricer;

use strict;
use warnings;
use JSON;
use Data::Dumper;
use Format::Util::Numbers qw(roundnear);
use BOM::WebSocketAPI::v3::Wrapper::System;
use Mojo::Redis::Processor;
use JSON::XS qw(encode_json decode_json);
use Time::HiRes qw(gettimeofday tv_interval);
use BOM::WebSocketAPI::v3::Wrapper::Streamer;
use Math::Util::CalculatedValue::Validatable;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);
use Format::Util::Numbers qw(to_monetary_number_format);
use Price::Calculator;

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
                app_markup_percentage => $c->stash('app_markup_percentage')
            },
            success => sub {
                my ($c, $rpc_response, $req_storage) = @_;
                my $cache = {
                    longcode            => $rpc_response->{longcode},
                    contract_parameters => delete $rpc_response->{contract_parameters}};
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

sub proposal_open_contract {
    my ($c, $response, $req_storage) = @_;

    my $args         = $req_storage->{args};
    my @contract_ids = keys %$response;
    return {
        msg_type               => 'proposal_open_contract',
        proposal_open_contract => {}} unless @contract_ids;

    my $send_details = sub {
        my $result = shift;
    };

    foreach my $contract_id (@contract_ids) {
        if (exists $response->{$contract_id}->{error}) {
            my $error =
                $c->new_error('proposal_open_contract', 'ContractValidationError', $c->l($response->{$contract_id}->{error}->{message_to_client}));
            $c->send({json => $error}, $req_storage);
        } else {
            my $uuid;

            if (    exists $args->{subscribe}
                and $args->{subscribe} eq '1'
                and not $response->{$contract_id}->{is_expired}
                and not $response->{$contract_id}->{is_sold})
            {
                # short_code contract_id currency is_sold sell_time are passed to pricer daemon and
                # are used to to identify redis channel and as arguments to get_bid rpc call
                # transaction_ids purchase_time buy_price should be stored and will be added to
                # every get_bid results and sent to client while streaming
                my $account_id = delete $response->{$contract_id}->{account_id};    # should not go to client
                my $cache      = {
                    account_id      => $account_id,
                    short_code      => $response->{$contract_id}->{shortcode},
                    contract_id     => $response->{$contract_id}->{contract_id},
                    currency        => $response->{$contract_id}->{currency},
                    buy_price       => $response->{$contract_id}->{buy_price},
                    sell_price      => $response->{$contract_id}->{sell_price},
                    sell_time       => $response->{$contract_id}->{sell_time},
                    purchase_time   => $response->{$contract_id}->{purchase_time},
                    is_sold         => $response->{$contract_id}->{is_sold},
                    transaction_ids => $response->{$contract_id}->{transaction_ids},
                    longcode        => $response->{$contract_id}->{longcode},
                };

                if (not $uuid = _pricing_channel_for_bid($c, $args, $cache)) {
                    my $error =
                        $c->new_error('proposal_open_contract', 'AlreadySubscribed', $c->l('You are already subscribed to proposal_open_contract.'));
                    $c->send({json => $error}, $req_storage);
                    next;
                } else {
                    # subscribe to transaction channel as when contract is manually sold we need to cancel streaming
                    BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'subscribe', $account_id,
                        $uuid, {contract_id => $contract_id});
                }
            }
            my $result = {$uuid ? (id => $uuid) : (), %{$response->{$contract_id}}};
            my $passthrough = $req_storage->{args}->{passthrough};
            delete $result->{rpc_time};
            $c->send({
                    json => {
                        msg_type               => 'proposal_open_contract',
                        proposal_open_contract => {%$result}
                    },
                    $passthrough ? (passthrough => $passthrough) : (),
                },
                $req_storage
            );
        }
    }
    return;
}

sub _serialized_args {
    my $h = shift;
    my @a = ();
    foreach my $k (sort keys %$h) {
        push @a, ($k, $h->{$k});
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

    $args_hash{language} = $c->stash('language') || 'EN';
    $args_hash{price_daemon_cmd} = $price_daemon_cmd;
    my $redis_channel = _serialized_args(\%args_hash);
    my $subchannel = $args->{amount_per_point} // $args->{amount};

    my $skip = BOM::WebSocketAPI::v3::Wrapper::Streamer::_skip_streaming($args);

    # uuid is needed regardless of whether its subscription or not
    return _create_pricer_channel($c, $args, $redis_channel, $subchannel, $price_daemon_cmd, $cache, $skip);
}

sub _pricing_channel_for_bid {
    my ($c, $args, $cache) = @_;
    my $price_daemon_cmd = 'bid';

    my %hash;
    @hash{qw(short_code contract_id currency sell_time)} = delete @{$cache}{qw(short_code contract_id currency sell_time)};
    $hash{is_sold} = $cache->{is_sold} + 0;
    $hash{language} = $c->stash('language') || 'EN';
    $hash{price_daemon_cmd} = $price_daemon_cmd;

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

    my $uuid = &BOM::WebSocketAPI::v3::Wrapper::Streamer::_generate_uuid_string();

    # subscribe if it is not already subscribed
    if (    exists $args->{subscribe}
        and $args->{subscribe} == 1
        and not exists $pricing_channel->{$redis_channel}
        and not $skip_redis_subscr)
    {
        $c->redis_pricer->set($redis_channel, 1);
        $c->stash('redis_pricer')->subscribe([$redis_channel], sub { });
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
            _prepare_results($results, $pricing_channel, $redis_channel, $stash_data);
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
        $c->send({json => $results});
    }
    return;
}

sub process_ask_event {
    my ($c, $response, $redis_channel, $pricing_channel) = @_;
    my $type = 'proposal';

    my $theo_probability = delete $response->{theo_probability};
    foreach my $stash_data (values %{$pricing_channel->{$redis_channel}}) {
        my $results;

        unless ($results = _get_validation_for_type($type)->($c, $response, $stash_data, {args => 'contract_type'})) {
            $stash_data->{cache}->{contract_parameters}->{longcode} = $stash_data->{cache}->{longcode};
            my $adjusted_results =
                _price_stream_results_adjustment($c, $stash_data->{args}, $stash_data->{cache}->{contract_parameters}, $response, $theo_probability);
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
            _prepare_results($results, $pricing_channel, $redis_channel, $stash_data);
        }
        if ($c->stash('debug')) {
            $results->{debug} = {
                time   => $results->{$type}->{rpc_time},
                method => $type,
            };
        }
        delete @{$results->{$type}}{qw(contract_parameters rpc_time)};
        $c->send({json => $results});
    }
    return;
}

sub _prepare_results {
    my ($results, $pricing_channel, $redis_channel, $stash_data) = @_;
    $results->{echo_req} = $stash_data->{args};
    if (my $passthrough = $stash_data->{args}->{passthrough}) {
        $results->{passthrough} = $passthrough;
    }
    if (my $req_id = $stash_data->{args}->{req_id}) {
        $results->{req_id} = $req_id;
    }
    return;
}

sub _price_stream_results_adjustment {
    my $c                     = shift;
    my $orig_args             = shift;
    my $contract_parameters   = shift;
    my $results               = shift;
    my $resp_theo_probability = shift;

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

    $contract_parameters->{theo_probability}      = $theo_probability;
    $contract_parameters->{app_markup_percentage} = $orig_args->{app_markup_percentage};

    my $price_calculator = Price::Calculator->new(%$contract_parameters);

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
        BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $uuid);
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

    #
    BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $stash_data->{uuid}) if $stash_data->{uuid};

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
        while (my ($key, $value) = each %$additional_params_to_check) {
            $err ||= !$stash_data->{$key}->{$value};
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
