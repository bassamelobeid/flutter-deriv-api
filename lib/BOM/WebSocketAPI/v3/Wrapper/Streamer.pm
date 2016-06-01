package BOM::WebSocketAPI::v3::Wrapper::Streamer;

use strict;
use warnings;

use JSON;
use Data::UUID;
use Scalar::Util qw (looks_like_number);
use List::MoreUtils qw(last_index);
use Format::Util::Numbers qw(roundnear);

use BOM::RPC::v3::Contract;
use BOM::RPC::v3::Japan::Contract;
use BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;
use BOM::WebSocketAPI::v3::Wrapper::System;
use Mojo::Redis::Processor;
use JSON::XS qw(encode_json decode_json);
use BOM::System::RedisReplicated;
use Time::HiRes qw(gettimeofday);
use utf8;

sub ticks {
    my ($c, $req_storage) = @_;

    my $args       = $req_storage->{args};
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

# this sub is different from others as we subscribe to feed channel first
# then call rpc, we cache the ticks from feed channel and when rpc response
# comes then we merge cache data with rpc response
sub ticks_history {
    my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};
    if ($args->{granularity} and not grep { $_ == $args->{granularity} } qw(60 120 180 300 600 900 1800 3600 7200 14400 28800 86400)) {
        return $c->new_error('ticks_history', "InvalidGranularity", $c->l('Granularity is not valid'));
    }

    my $publish;
    my $style = $args->{style} || ($args->{granularity} ? 'candles' : 'ticks');
    if ($style eq 'ticks') {
        $publish = 'tick';
    } elsif ($style eq 'candles') {
        $args->{granularity} = $args->{granularity} || 60;
        $publish = $args->{granularity};
    } else {
        return $c->new_error('ticks_history', "InvalidStyle", $c->l('Style [_1] invalid', $style));
    }

    my $callback = sub {
        $c->call_rpc({
                args            => $args,
                method          => 'ticks_history',
                rpc_response_cb => sub {
                    my ($c, $args, $rpc_response) = @_;
                    if (exists $rpc_response->{error}) {
                        # cancel subscription if response has error
                        _feed_channel($c, 'unsubscribe', $args->{ticks_history}, $publish, $args);
                        return $c->new_error('ticks_history', $rpc_response->{error}->{code}, $rpc_response->{error}->{message_to_client});
                    }

                    my $channel = $args->{ticks_history} . ';' . $publish;
                    my $feed_channel_cache = $c->stash('feed_channel_cache') || {};

                    # check for cached data
                    if (exists $feed_channel_cache->{$channel} and scalar(keys %{$feed_channel_cache->{$channel}})) {
                        my $cache = $feed_channel_cache->{$channel};
                        # both history and candles have different structure, check rpc ticks_history sub
                        if ($rpc_response->{type} eq 'history') {
                            my %times;
                            # store whats in cache
                            @times{keys %$cache} = map { $_->{quote} } values %$cache;
                            # merge with response data
                            @times{@{$rpc_response->{data}->{history}->{times}}} = @{$rpc_response->{data}->{history}->{prices}};
                            @{$rpc_response->{data}->{history}->{times}} = sort { $a <=> $b } keys %times;
                            @{$rpc_response->{data}->{history}->{prices}} = @times{@{$rpc_response->{data}->{history}->{times}}};
                        } elsif ($rpc_response->{type} eq 'candles') {
                            my $index;
                            my $candles = $rpc_response->{data}->{candles};

                            # delete all cache value that have epoch lower than last candle epoch
                            my @matches = grep { $_ < $candles->[-1]->{epoch} } keys %$cache;
                            delete @$cache{@matches};

                            foreach my $epoch (sort { $a <=> $b } keys %$cache) {
                                my $window = $epoch - $epoch % $publish;
                                # check if window exists in candles response
                                $index = last_index { $_->{epoch} eq $window } @$candles;
                                # if no window is in response then update the candles with cached data
                                if ($index < 0) {
                                    push @$candles, {
                                        open  => $cache->{$epoch}->{open},
                                        close => $cache->{$epoch}->{close},
                                        epoch => $window + 0,                 # need to send as integer
                                        high  => $cache->{$epoch}->{high},
                                        low   => $cache->{$epoch}->{low}};
                                } else {
                                    # if window exists replace it with new data
                                    $candles->[$index] = {
                                        open  => $cache->{$epoch}->{open},
                                        close => $cache->{$epoch}->{close},
                                        epoch => $window + 0,                 # need to send as integer
                                        high  => $cache->{$epoch}->{high},
                                        low   => $cache->{$epoch}->{low}};
                                }
                            }
                        }

                        delete $feed_channel_cache->{$channel};
                    }

                    my $feed_channel_type = $c->stash('feed_channel_type') || {};
                    # remove the cache flag which was set during subscription
                    delete $feed_channel_type->{$channel}->{cache} if exists $feed_channel_type->{$channel};

                    return {
                        msg_type => $rpc_response->{type},
                        %{$rpc_response->{data}}};
                }
            });
    };

    # subscribe first with flag of cache passed as 1 to indicate to cache the feed data
    if (exists $args->{subscribe} and $args->{subscribe} eq '1') {
        if (not _feed_channel($c, 'subscribe', $args->{ticks_history}, $publish, $args, $callback, 1)) {
            return $c->new_error('ticks_history', 'AlreadySubscribed', $c->l('You are already subscribed to [_1]', $args->{ticks_history}));
        }
    } else {
        &$callback;
    }

    return;
}

sub proposal {
    my ($c, $req_storage) = @_;

    my $args     = $req_storage->{args};
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

sub pricing_table {
    my ($c, $req_storage) = @_;

    my $args     = $req_storage->{args};
    my $response = BOM::RPC::v3::Japan::Contract::validate_table_props($args);

    if ($response and exists $response->{error}) {
        return $c->new_error('pricing_table',
            $response->{error}->{code}, $c->l($response->{error}->{message}, @{$response->{error}->{params} || []}));
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
    my ($c, $id, $req_storage) = @_;

    $c->call_rpc({
            args     => $req_storage,
            id       => $id,
            method   => 'send_ask',
            msg_type => 'proposal',
            error    => sub {
                my ($c, $rpc_response, $req_storage) = @_;
                BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $req_storage->{id});
            },
            response => sub {
                my ($rpc_response, $api_response, $req_storage) = @_;

                if ($api_response->{error}) {
                    $api_response->{error}->{details} = $rpc_response->{error}->{details} if (exists $rpc_response->{error}->{details});
                } else {
                    $api_response->{proposal}->{id} = $req_storage->{id} if $req_storage->{id};
                }
                return $api_response;
            }
        });
    return;
}

sub process_realtime_events {
    my ($c, $message, $chan) = @_;

    my @m                  = split(';', $message);
    my $feed_channels_type = $c->stash('feed_channel_type');
    my $feed_channel_cache = $c->stash('feed_channel_cache') || {};

    foreach my $channel (keys %{$feed_channels_type}) {
        $channel =~ /(.*);(.*)/;
        my $symbol    = $1;
        my $type      = $2;
        my $arguments = $feed_channels_type->{$channel}->{args};
        my $cache     = $feed_channels_type->{$channel}->{cache};

        if ($type eq 'tick' and $m[0] eq $symbol) {
            unless ($c->tx) {
                _feed_channel($c, 'unsubscribe', $symbol, $type, $arguments);
                return;
            }

            my $tick = {
                id     => $feed_channels_type->{$channel}->{uuid},
                symbol => $symbol,
                epoch  => $m[1],
                quote  => BOM::Market::Underlying->new($symbol)->pipsized_value($m[2])};

            if ($cache) {
                $feed_channel_cache->{$channel}->{$m[1]} = $tick;
            } else {
                $c->send({
                        json => {
                            msg_type => 'tick',
                            echo_req => $arguments,
                            (exists $arguments->{req_id})
                            ? (req_id => $arguments->{req_id})
                            : (),
                            tick => $tick
                        }}) if $c->tx;
            }
        } elsif ($type =~ /^pricing_table:/) {
            if ($chan eq BOM::RPC::v3::Japan::Contract::get_channel_name($arguments)) {
                send_pricing_table($c, $feed_channels_type->{$channel}->{uuid}, $arguments, $message);
            }
        } elsif ($type =~ /^proposal:/ and $m[0] eq $symbol) {
            if (exists $arguments->{subscribe} and $arguments->{subscribe} eq '1') {
                return unless $c->tx;
                send_ask($c, $feed_channels_type->{$channel}->{uuid}, $arguments) if not _skip_streaming($arguments);
            } else {
                return;
            }
        } elsif ($type =~ /^proposal_open_contract:/ and $m[0] eq $symbol) {
            BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::send_proposal($c, $feed_channels_type->{$channel}->{uuid}, $arguments)
                if $c->tx;
        } elsif ($m[0] eq $symbol) {
            unless ($c->tx) {
                _feed_channel($c, 'unsubscribe', $symbol, $type, $arguments);
                return;
            }

            my $u = BOM::Market::Underlying->new($symbol);
            $message =~ /;$type:([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+);/;
            my $ohlc = {
                id        => $feed_channels_type->{$channel}->{uuid},
                epoch     => $m[1],
                open_time => ($type and looks_like_number($type))
                ? $m[1] - $m[1] % $type
                : $m[1] - $m[1] % 60,    #defining default granularity
                symbol      => $symbol,
                granularity => $type,
                open        => $u->pipsized_value($1),
                high        => $u->pipsized_value($2),
                low         => $u->pipsized_value($3),
                close       => $u->pipsized_value($4)};

            if ($cache) {
                $feed_channel_cache->{$channel}->{$m[1]} = $ohlc;
            } else {
                $c->send({
                        json => {
                            msg_type => 'ohlc',
                            echo_req => $arguments,
                            (exists $arguments->{req_id})
                            ? (req_id => $arguments->{req_id})
                            : (),
                            ohlc => $ohlc
                        }}) if $c->tx;
            }
        }
    }
    $c->stash('feed_channel_cache', $feed_channel_cache);

    return;
}

sub _feed_channel {
    my ($c, $subs, $symbol, $type, $args, $callback, $cache) = @_;

    my $uuid;
    my $feed_channel       = $c->stash('feed_channel')       || {};
    my $feed_channel_type  = $c->stash('feed_channel_type')  || {};
    my $feed_channel_cache = $c->stash('feed_channel_cache') || {};

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
        $feed_channel_type->{"$symbol;$type"}->{args}  = $args if $args;
        $feed_channel_type->{"$symbol;$type"}->{uuid}  = $uuid;
        $feed_channel_type->{"$symbol;$type"}->{cache} = $cache || 0;

        my $channel_name = ($type =~ /pricing_table/) ? BOM::RPC::v3::Japan::Contract::get_channel_name($args) : "FEED::$symbol";
        $redis->subscribe([$channel_name], $callback // sub { });
    }

    if ($subs eq 'unsubscribe') {
        $feed_channel->{$symbol} -= 1;
        my $args = $feed_channel_type->{"$symbol;$type"}->{args};
        $uuid = $feed_channel_type->{"$symbol;$type"}->{uuid};
        delete $feed_channel_type->{"$symbol;$type"};
        # delete cache on unsubscribe
        delete $feed_channel_cache->{"$symbol;$type"};

        # as we subscribe to transaction channel for proposal_open_contract so need to forget that also
        _transaction_channel($c, 'unsubscribe', $args->{account_id}, $uuid) if $type =~ /^proposal_open_contract:/;

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
            $channel->{$type}->{args}        = $args;
            $channel->{$type}->{uuid}        = $uuid;
            $channel->{$type}->{account_id}  = $account_id;
            $channel->{$type}->{contract_id} = $args->{contract_id};
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
                _transaction_channel($c, 'unsubscribe', $channel->{$type}->{account_id}, $type);
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

                            $c->call_rpc({
                                    args        => $args,
                                    method      => 'get_contract_details',
                                    call_params => {
                                        token      => $c->stash('token'),
                                        short_code => $payload->{short_code},
                                        currency   => $payload->{currency_code},
                                        language   => $c->stash('language'),
                                    },
                                    rpc_response_cb => sub {
                                        my ($c, $args, $rpc_response) = @_;

                                        if (exists $rpc_response->{error}) {
                                            BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
                                            return $c->new_error(
                                                'transaction',
                                                $rpc_response->{error}->{code},
                                                $rpc_response->{error}->{message_to_client});
                                        } else {
                                            $details->{$type}->{contract_id}   = $payload->{financial_market_bet_id};
                                            $details->{$type}->{purchase_time} = Date::Utility->new($payload->{purchase_time})->epoch
                                                if ($payload->{action_type} eq 'sell');
                                            $details->{$type}->{longcode}     = $rpc_response->{longcode};
                                            $details->{$type}->{symbol}       = $rpc_response->{symbol};
                                            $details->{$type}->{display_name} = $rpc_response->{display_name};
                                            $details->{$type}->{date_expiry}  = $rpc_response->{date_expiry};
                                            return $details;
                                        }
                                    },
                                });
                        } else {
                            $details->{$type}->{longcode}         = $payload->{payment_remark};
                            $details->{$type}->{transaction_time} = Date::Utility->new($payload->{payment_time})->epoch;
                            $c->send({json => $details});
                        }
                    } elsif ($type =~ /\w{8}-\w{4}-\w{4}-\w{4}-\w{12}/
                        and $payload->{action_type} eq 'sell'
                        and exists $payload->{financial_market_bet_id}
                        and $payload->{financial_market_bet_id} eq $channel->{$type}->{contract_id})
                    {
                        # cancel proposal open contract streaming which will cancel transaction subscription also
                        BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $type);

                        $args->{is_sold}    = 1;
                        $args->{sell_price} = $payload->{amount};
                        $args->{sell_time}  = Date::Utility->new($payload->{sell_time})->epoch;

                        # send proposal details last time
                        BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::send_proposal($c, undef, $args);
                    }
                } elsif ($channel and exists $channel->{$type}->{account_id}) {
                    _transaction_channel($c, 'unsubscribe', $channel->{$type}->{account_id}, $type);
                }
            }
        }
    }
    return;
}

sub send_pricing_table {
    my $c            = shift;
    my $id           = shift;
    my $arguments    = shift;
    my $message      = shift;
    my $params_table = JSON::from_json($message // "{}");                                        # BOM::RPC::v3::Japan::Contract::get_table
                                                                                                 # returns undef while running tests
    my $table        = BOM::RPC::v3::Japan::Contract::update_table($arguments, $params_table);

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

sub _skip_streaming {
    my $args = shift;

    my %skip_duration_list = map { $_ => 1 } qw(s m h);
    my %skip_symbol_list   = map { $_ => 1 } qw(R_100 R_50 R_25 R_75 RDBULL RDBEAR);
    my %skip_type_list     = map { $_ => 1 } qw(CALL PUT DIGITMATCH DIGITDIFF DIGITOVER DIGITUNDER DIGITODD DIGITEVEN);

    my $skip_symbols = ($skip_symbol_list{$args->{symbol}}) ? 1 : 0;
    my $atm_contract = ($args->{contract_type} =~ /^(CALL|PUT)$/ and not $args->{barrier}) ? 1 : 0;
    my $fixed_expiry = $args->{date_expiry} ? 1 : 0;
    my ($skip_tick_expiry, $skip_intraday_atm_non_fixed_expiry) = (0, 0);
    if (defined $args->{duration_unit}) {
        $skip_tick_expiry =
            ($skip_symbols and $skip_type_list{$args->{contract_type}} and $args->{duration_unit} eq 't');
        $skip_intraday_atm_non_fixed_expiry =
            ($skip_symbols and $skip_duration_list{$args->{duration_unit}} and $atm_contract and not $fixed_expiry);
    }

    return 1 if ($skip_tick_expiry or $skip_intraday_atm_non_fixed_expiry);
    return;
}

1;
