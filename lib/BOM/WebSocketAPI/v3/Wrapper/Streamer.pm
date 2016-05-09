package BOM::WebSocketAPI::v3::Wrapper::Streamer;

use strict;
use warnings;

use JSON;
use Data::UUID;
use Scalar::Util qw (looks_like_number);
use Format::Util::Numbers qw(roundnear);

use BOM::RPC::v3::Contract;
use BOM::RPC::v3::Japan::Contract;
use BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;
use BOM::WebSocketAPI::v3::Wrapper::System;
use Mojo::Redis::Processor;
use JSON::XS qw(encode_json decode_json);
use BOM::System::RedisReplicated;

sub ticks {
    my ($c, $args) = @_;

    my $send_error = sub {
        my ($code, $message) = @_;
        $c->send({
                json => {
                    msg_type => 'tick',
                    echo_req => $args,
                    (exists $args->{req_id})
                    ? (req_id => $args->{req_id})
                    : (),
                    error => {
                        code    => $code,
                        message => $message
                    }}});
    };

    my @symbols = (ref $args->{ticks}) ? @{$args->{ticks}} : ($args->{ticks});
    foreach my $symbol (@symbols) {
        my $response = BOM::RPC::v3::Contract::validate_underlying($symbol);
        if ($response and exists $response->{error}) {
            $send_error->($response->{error}->{code}, $c->l($response->{error}->{message}, $symbol));
        } elsif (not _feed_channel($c, 'subscribe', $symbol, 'tick', $args)) {
            $send_error->('AlreadySubscribed', $c->l('You are already subscribed to [_1]', $symbol));
        }
    }
    return;
}

sub ticks_history {
    my ($c, $args) = @_;

    if ($args->{granularity} and not grep { $_ == $args->{granularity} } qw(60 120 180 300 600 900 1800 3600 7200 14400 28800 86400)) {
        return $c->new_error('ticks_history', "InvalidGranularity", $c->l('Granularity is not valid'));
    }

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'ticks_history',
        sub {
            my $response = shift;
            if ($response and exists $response->{error}) {
                return $c->new_error('ticks_history', $response->{error}->{code}, $response->{error}->{message_to_client});
            }

            if (exists $args->{subscribe}) {
                if ($args->{subscribe} eq '1') {
                    $args->{granularity} = $response->{granularity} if $response->{granularity};
                    if (not _feed_channel($c, 'subscribe', $args->{ticks_history}, $response->{publish}, $args)) {
                        return $c->new_error('ticks_history',
                            'AlreadySubscribed', $c->l('You are already subscribed to [_1]', $args->{ticks_history}));
                    }
                }
            }
            return {
                msg_type => $response->{type},
                %{$response->{data}}};
        },
        {args => $args});

    return;
}

sub price_stream {
    my ($c, $args) = @_;

    my $symbol   = $args->{symbol};
    my $response = BOM::RPC::v3::Contract::validate_symbol($symbol);
    if ($response and exists $response->{error}) {
        return $c->new_error('proposal', $response->{error}->{code}, $c->l($response->{error}->{message}, $symbol));
    } else {
        my $id;
        if ($args->{subscribe} == 1 and not $id = _pricing_channel($c, 'subscribe', $args)) {
            return $c->new_error('proposal',
                'AlreadySubscribedOrLimit', $c->l('You are either already subscribed or you have reached the limit for proposal subscription.'));
        }
        send_ask($c, $id, $args);
    }
    return;
}

sub proposal {
    my ($c, $args) = @_;

    my $symbol   = $args->{symbol};
    my $response = BOM::RPC::v3::Contract::validate_symbol($symbol);
    if ($response and exists $response->{error}) {
        return $c->new_error('proposal', $response->{error}->{code}, $c->l($response->{error}->{message}, $symbol));
    } else {
        my $id;
        if (not $id = _feed_channel($c, 'subscribe', $symbol, 'proposal:' . JSON::to_json($args), $args)) {
            return $c->new_error('proposal',
                'AlreadySubscribedOrLimit', $c->l('You are either already subscribed or you have reached the limit for proposal subscription.'));
        }
        send_ask($c, $id, $args);
    }
    return;
}

sub _serialized_args {
    my $h = shift;
    my @a = ();
    foreach my $k (sort keys %$h) {
        push @a, ($k, $h->{$k});
    }
    return encode_json(\@a);
}

sub process_pricing_events {
    my ($c, $message, $chan) = @_;

    my $response        = decode_json($message);
    my $serialized_args = $response->{data};

    my $pricing_channel = $c->stash('pricing_channel');
    return if not $pricing_channel or not $pricing_channel->{$serialized_args};
    BOM::System::RedisReplicated::redis_write->expire($response->{key}, 60);

    delete $response->{data};
    delete $response->{key};

    foreach my $amount (keys %{$pricing_channel->{$serialized_args}}) {
        next if  $amount eq 'channel_name';
        my $results;
        if ($response and exists $response->{error}) {
            my $err = $c->new_error('proposal', $response->{error}->{code}, $response->{error}->{message_to_client});
            $err->{error}->{details} = $response->{error}->{details} if (exists $response->{error}->{details});
            $results = $err;
        } else {
            $results = {
                msg_type => 'proposal',
                proposal => $response,
            };
            $results->{proposal}->{ask_price} *= roundnear(0.01, $amount / 1000);
            if (not exist $results->{proposal}->{spread}) {
                $results->{proposal}->{display_value} *= roundnear(0.01, $amount / 1000);
            }
            $results->{proposal}->{id} = $pricing_channel->{$serialized_args}->{$amount}->{uuid};
        }
        BOM::WebSocketAPI::Websocket_v3::_process_result($c, $results, 'proposal', $pricing_channel->{$serialized_args}->{$amount}->{args},
            undef, undef);
    }
    return;
}

sub _pricing_channel {
    my ($c, $subs, $args) = @_;

    my %args_hash = %{$args};
    $args_hash{amount} = 1000;
    $args_hash{language} = $c->stash('language') || 'EN';
    my $serialized_args = _serialized_args(\%args_hash);

    my $pricing_channel = $c->stash('pricing_channel') || {};

    if ($pricing_channel->{$serialized_args} and $pricing_channel->{$serialized_args}->{$args->{amount}}) {
        return;
    }

    my $uuid;
    if (not $pricing_channel->{$serialized_args}) {
        my $rp = Mojo::Redis::Processor->new({
            'write_conn' => BOM::System::RedisReplicated::redis_write,
            'read_conn'  => BOM::System::RedisReplicated::redis_read,
            data         => $serialized_args,
            trigger      => 'FEED::' . $args->{symbol},
        });
        $rp->send();
        $c->stash('redis')->subscribe([$rp->_processed_channel], sub { });

        $uuid = Data::UUID->new->create_str();
        $pricing_channel->{$serialized_args}->{$args->{amount}}->{uuid} = $uuid;
        $pricing_channel->{$serialized_args}->{$args->{amount}}->{args} = $args;
        $pricing_channel->{$serialized_args}->{channel_name}            = $rp->_processed_channel;

        $c->stash('pricing_channel' => $pricing_channel);
    }
    return $uuid;
}

sub pricing_table {
    my ($c, $args) = @_;

    my $response = BOM::RPC::v3::Japan::Contract::validate_table_props($args);

    if ($response and exists $response->{error}) {
        return $c->new_error('pricing_table', $response->{error}->{code},
            $c->l($response->{error}->{message}, @{$response->{error}->{params} || []}));
    }

    my $symbol = $args->{symbol};
    my $id;
    if (not $id = _feed_channel($c, 'subscribe', $symbol, 'pricing_table:' . JSON::to_json($args), $args)) {
        return $c->new_error('pricing_table',
            'AlreadySubscribedOrLimit', $c->l('You are either already subscribed or you have reached the limit for pricing table subscription.'));
    }
    my $msg = BOM::RPC::v3::Japan::Contract::get_table($args);
    send_pricing_table($c, $id, $args, $msg);

    return;
}

sub send_ask {
    my ($c, $id, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'send_ask',
        sub {
            my $response = shift;
            if ($response and exists $response->{error}) {
                BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id);
                my $err = $c->new_error('proposal', $response->{error}->{code}, $response->{error}->{message_to_client});
                $err->{error}->{details} = $response->{error}->{details} if (exists $response->{error}->{details});
                return $err;
            }
            return {
                msg_type => 'proposal',
                proposal => {($id ? (id => $id) : ()), %$response}};
        },
        {args => $args},
        'proposal'
    );
    return;
}

sub process_realtime_events {
    my ($c, $message, $chan) = @_;

    my @m                  = split(';', $message);
    my $feed_channels_type = $c->stash('feed_channel_type');
    my %skip_duration_list = map { $_ => 1 } qw(s m h);
    my %skip_symbol_list   = map { $_ => 1 } qw(R_100 R_50 R_25 R_75 RDBULL RDBEAR RDYIN RDYANG);
    my %skip_type_list     = map { $_ => 1 } qw(CALL PUT DIGITMATCH DIGITDIFF DIGITOVER DIGITUNDER DIGITODD DIGITEVEN);
    foreach my $channel (keys %{$feed_channels_type}) {
        $channel =~ /(.*);(.*)/;
        my $symbol    = $1;
        my $type      = $2;
        my $arguments = $feed_channels_type->{$channel}->{args};

        if ($type eq 'tick' and $m[0] eq $symbol) {
            $c->send({
                    json => {
                        msg_type => 'tick',
                        echo_req => $arguments,
                        (exists $arguments->{req_id})
                        ? (req_id => $arguments->{req_id})
                        : (),
                        tick => {
                            id     => $feed_channels_type->{$channel}->{uuid},
                            symbol => $symbol,
                            epoch  => $m[1],
                            quote  => BOM::Market::Underlying->new($symbol)->pipsized_value($m[2])}}}) if $c->tx;
        } elsif ($type =~ /^pricing_table:/) {
            if ($chan eq BOM::RPC::v3::Japan::Contract::get_channel_name($arguments)) {
                send_pricing_table($c, $feed_channels_type->{$channel}->{uuid}, $arguments, $message);
            }
        } elsif ($type =~ /^proposal:/ and $m[0] eq $symbol) {
            if (exists $arguments->{subscribe} and $arguments->{subscribe} eq '1') {
                return unless $c->tx;
                my $skip_symbols = ($skip_symbol_list{$arguments->{symbol}}) ? 1 : 0;
                my $atm_contract = ($arguments->{contract_type} =~ /^(CALL|PUT)$/ and not $arguments->{barrier}) ? 1 : 0;
                my $fixed_expiry = $arguments->{date_expiry} ? 1 : 0;
                my $skip_tick_expiry =
                    ($skip_symbols and $skip_type_list{$arguments->{contract_type}} and $arguments->{duration_unit} eq 't');
                my $skip_intraday_atm_non_fixed_expiry =
                    ($skip_symbols and $skip_duration_list{$arguments->{duration_unit}} and $atm_contract and not $fixed_expiry);

                if (not $skip_tick_expiry and not $skip_intraday_atm_non_fixed_expiry) {
                    send_ask($c, $feed_channels_type->{$channel}->{uuid}, $arguments);
                }
            } else {
                return;
            }
        } elsif ($type =~ /^proposal_open_contract:/ and $m[0] eq $symbol) {
            BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::send_proposal($c, $feed_channels_type->{$channel}->{uuid}, $arguments)
                if $c->tx;
        } elsif ($m[0] eq $symbol) {
            my $u = BOM::Market::Underlying->new($symbol);
            $message =~ /;$type:([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+);/;
            $c->send({
                    json => {
                        msg_type => 'ohlc',
                        echo_req => $arguments,
                        (exists $arguments->{req_id}) ? (req_id => $arguments->{req_id})
                        : (),
                        ohlc => {
                            id        => $feed_channels_type->{$channel}->{uuid},
                            epoch     => $m[1],
                            open_time => ($type and looks_like_number($type)) ? $m[1] - $m[1] % $type
                            : $m[1] - $m[1] % 60,    #defining default granularity
                            symbol      => $symbol,
                            granularity => $type,
                            open        => $u->pipsized_value($1),
                            high        => $u->pipsized_value($2),
                            low         => $u->pipsized_value($3),
                            close       => $u->pipsized_value($4)}}}) if $c->tx;
        }
    }

    return;
}

sub _feed_channel {

    my ($c, $subs, $symbol, $type, $args) = @_;

    my $uuid;

    my $feed_channel      = $c->stash('feed_channel')      || {};
    my $feed_channel_type = $c->stash('feed_channel_type') || {};

    my $redis = $c->stash('redis');
    if ($subs eq 'subscribe') {
        my $count = 0;
        foreach my $k (keys $feed_channel_type) {
            $count++ if ($k =~ /^.*?;(?:proposal|pricing_table):/);
        }
        if ($count > 5 || exists $feed_channel_type->{"$symbol;$type"}) {
            return;
        }
        $uuid = Data::UUID->new->create_str();
        $feed_channel->{$symbol} += 1;
        $feed_channel_type->{"$symbol;$type"}->{args} = $args if $args;
        $feed_channel_type->{"$symbol;$type"}->{uuid} = $uuid;

        my $channel_name = ($type =~ /pricing_table/) ? BOM::RPC::v3::Japan::Contract::get_channel_name($args) : "FEED::$symbol";
        $redis->subscribe([$channel_name], sub { });
    }

    if ($subs eq 'unsubscribe') {
        $feed_channel->{$symbol} -= 1;
        my $args = $feed_channel_type->{"$symbol;$type"}->{args};
        delete $feed_channel_type->{"$symbol;$type"};
        if ($feed_channel->{$symbol} <= 0) {
            my $channel_name = ($type =~ /pricing_table/) ? BOM::RPC::v3::Japan::Contract::get_channel_name($args) : "FEED::$symbol";
            $redis->unsubscribe([$channel_name], sub { });
            delete $feed_channel->{$symbol};
        }
    }

    $c->stash('feed_channel'      => $feed_channel);
    $c->stash('feed_channel_type' => $feed_channel_type);

    return $uuid;
}

sub _transaction_channel {
    my ($c, $action, $account_id, $type, $args) = @_;
    my $uuid;

    my $redis              = $c->stash('redis');
    my $channel            = $c->stash('transaction_channel');
    my $already_subscribed = $channel ? exists $channel->{$type} : undef;

    if ($action) {
        my $channel_name = 'TXNUPDATE::transaction_' . $account_id;
        if ($action eq 'subscribe' and not $already_subscribed) {
            $uuid = Data::UUID->new->create_str();
            $redis->subscribe([$channel_name], sub { }) unless (keys %$channel);
            $channel->{$type}->{args}       = $args if $args;
            $channel->{$type}->{uuid}       = $uuid;
            $channel->{$type}->{account_id} = $account_id;
            $c->stash('transaction_channel', $channel);
        } elsif ($action eq 'unsubscribe' and $already_subscribed) {
            delete $channel->{$type};
            unless (keys %$channel) {
                $redis->unsubscribe([$channel_name], sub { });
                delete $c->stash->{transaction_channel};
            }
        }
    }

    return $uuid;
}

sub process_transaction_updates {
    my ($c, $message) = @_;
    my $channel = $c->stash('transaction_channel');

    if ($channel) {
        my $payload = JSON::from_json($message);
        my $args    = {};
        foreach my $type (keys %{$channel}) {
            if ($payload and exists $payload->{error} and exists $payload->{error}->{code} and $payload->{error}->{code} eq 'TokenDeleted') {
                BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $channel->{$type}->{account_id}, $type);
            } else {
                $args = (exists $channel->{$type}->{args}) ? $channel->{$type}->{args} : {};

                my $id;
                $id = ($channel and exists $channel->{$type}->{uuid}) ? $channel->{$type}->{uuid} : undef;

                my $details = {
                    msg_type => $type,
                    $args ? (echo_req => $args) : (),
                    ($args and exists $args->{req_id}) ? (req_id => $args->{req_id}) : (),
                    $type => {$id ? (id => $id) : ()}};

                if ($c->stash('account_id')) {
                    if ($type eq 'balance') {
                        $details->{$type}->{loginid}  = $c->stash('loginid');
                        $details->{$type}->{currency} = $c->stash('currency');
                        $details->{$type}->{balance}  = $payload->{balance_after};
                        $c->send({json => $details}) if $c->tx;
                    } elsif ($type eq 'transaction') {
                        $details->{$type}->{balance}        = $payload->{balance_after};
                        $details->{$type}->{action}         = $payload->{action_type};
                        $details->{$type}->{amount}         = $payload->{amount};
                        $details->{$type}->{transaction_id} = $payload->{id};
                        $payload->{currency_code} ? ($details->{$type}->{currency} = $payload->{currency_code}) : ();

                        if (exists $payload->{referrer_type} and $payload->{referrer_type} eq 'financial_market_bet') {
                            $details->{$type}->{transaction_time} =
                                ($payload->{action_type} eq 'sell')
                                ? Date::Utility->new($payload->{sell_time})->epoch
                                : Date::Utility->new($payload->{purchase_time})->epoch;

                            BOM::WebSocketAPI::Websocket_v3::rpc(
                                $c,
                                'get_contract_details',
                                sub {
                                    my $response = shift;
                                    if (exists $response->{error}) {
                                        BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
                                        return $c->new_error('transaction', $response->{error}->{code}, $response->{error}->{message_to_client});
                                    } else {
                                        $details->{$type}->{contract_id}   = $payload->{financial_market_bet_id};
                                        $details->{$type}->{purchase_time} = Date::Utility->new($payload->{purchase_time})->epoch
                                            if ($payload->{action_type} eq 'sell');
                                        $details->{$type}->{longcode}     = $response->{longcode};
                                        $details->{$type}->{symbol}       = $response->{symbol};
                                        $details->{$type}->{display_name} = $response->{display_name};
                                        $details->{$type}->{date_expiry}  = $response->{date_expiry};
                                        return $details;
                                    }
                                },
                                {
                                    args       => $args,
                                    token      => $c->stash('token'),
                                    short_code => $payload->{short_code},
                                    currency   => $payload->{currency_code},
                                    language   => $c->stash('language'),
                                });
                        } else {
                            $details->{$type}->{longcode}         = $payload->{payment_remark};
                            $details->{$type}->{transaction_time} = Date::Utility->new($payload->{payment_time})->epoch;
                            $c->send({json => $details});
                        }
                    } elsif ($type =~ /^[0-9]+$/
                        and $payload->{action_type} eq 'sell'
                        and exists $payload->{financial_market_bet_id}
                        and $payload->{financial_market_bet_id} eq $type)
                    {
                        # cancel proposal open contract streaming, transaction subscription and mark is_sold as 1
                        BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel(
                            $c, 'unsubscribe',
                            delete $args->{underlying},
                            'proposal_open_contract:' . JSON::to_json($args), $args
                        ) if $args->{underlying};
                        BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $channel->{$type}->{account_id}, $type);

                        $args->{is_sold}    = 1;
                        $args->{sell_price} = $payload->{amount};
                        $args->{sell_time}  = Date::Utility->new($payload->{sell_time})->epoch;

                        # send proposal details last time
                        BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::send_proposal($c, undef, $args);
                    }
                } elsif ($channel and exists $channel->{$type}->{account_id}) {
                    BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $channel->{$type}->{account_id}, $type);
                }
            }
        }
    }
    return;
}

sub send_pricing_table {
    my $c         = shift;
    my $id        = shift;
    my $arguments = shift;
    my $message   = shift;
    my $table     = JSON::from_json($message);
    $c->send({
            json => {
                msg_type => 'pricing_table',
                echo_req => $arguments,
                (exists $arguments->{req_id})
                ? (req_id => $arguments->{req_id})
                : (),
                (
                    pricing_table => {
                        id     => $id,
                        prices => $table,
                    })}});
    return;
}

1;
