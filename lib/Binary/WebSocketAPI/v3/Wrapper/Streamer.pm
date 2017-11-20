package Binary::WebSocketAPI::v3::Wrapper::Streamer;

use strict;
use warnings;

use Date::Utility;
use Mojo::Redis::Processor;
use Time::HiRes qw(gettimeofday);
use List::MoreUtils qw(last_index);
use JSON::MaybeXS;
use Scalar::Util qw (looks_like_number refaddr weaken);
use Format::Util::Numbers qw/formatnumber/;

use Binary::WebSocketAPI::v3::Wrapper::Pricer;
use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Instance::Redis qw( ws_redis_master shared_redis );

use utf8;
use Try::Tiny;

my $utf8_json = JSON::MaybeXS->new->utf8(1);

sub website_status {
    my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};

    ### TODO: to config
    my $channel_name = "NOTIFY::broadcast::channel";
    my $redis        = ws_redis_master;
    my $shared_info  = $redis->{shared_info};

    my $callback = sub {
        $c->call_rpc({
                args        => $args,
                method      => 'website_status',
                call_params => {
                    country_code => $c->country_code,
                },
                response => sub {
                    my $rpc_response   = shift;
                    my $website_status = {};
                    $rpc_response->{clients_country} //= '';
                    $website_status->{$_} = $rpc_response->{$_}
                        for qw|api_call_limits clients_country supported_languages terms_conditions_version currencies_config|;

                    $shared_info->{broadcast_notifications}{$c + 0}{'c'}            = $c;
                    $shared_info->{broadcast_notifications}{$c + 0}{echo}           = $args;
                    $shared_info->{broadcast_notifications}{$c + 0}{website_status} = $rpc_response;

                    Scalar::Util::weaken($shared_info->{broadcast_notifications}{$c + 0}{'c'});

                    ### to config
                    my $current_state = ws_redis_master()->get("NOTIFY::broadcast::state");

                    $current_state = eval { $utf8_json->decode($current_state) }
                        if $current_state && !ref $current_state;
                    $website_status->{site_status} = $current_state->{site_status} // 'up';
                    $website_status->{message}     = $current_state->{message}     // ''
                        if $website_status->{site_status} eq 'down';

                    return {
                        website_status => $website_status,
                        msg_type       => 'website_status'
                    };
                }
            });
    };

    if (!$args->{subscribe} || $args->{subscribe} == 0) {
        delete $shared_info->{broadcast_notifications}{$c + 0};
        &$callback();
        return;
    }
    if ($shared_info->{broadcast_notifications}{$c + 0}) {
        &$callback();
        return;
    }

    $redis->subscribe([$channel_name], $callback);
    return;
}

sub send_notification {
    my ($shared, $message, $channel) = @_;

    return if !$shared || !ref $shared || !$shared->{broadcast_notifications} || !ref $shared->{broadcast_notifications};
    my $is_on_key = 0;
    foreach my $c_addr (keys %{$shared->{broadcast_notifications}}) {
        unless (defined $shared->{broadcast_notifications}{$c_addr}{c}) {
            # connection gone...
            delete $shared->{broadcast_notifications}{$c_addr};
            next;
        }
        my $client_shared = $shared->{broadcast_notifications}{$c_addr};
        unless (defined $client_shared->{c}->tx) {
            delete $shared->{broadcast_notifications}{$c_addr};
            ws_redis_master->unsubscribe([$channel])
                if (scalar keys %{$shared->{broadcast_notifications}}) == 0 && $channel;
            next;
        }

        unless ($is_on_key) {
            $is_on_key = "NOTIFY::broadcast::is_on";    ### TODO: to config
            return unless ws_redis_master()->get($is_on_key);    ### Need 1 for continuing
        }

        $message = eval { $utf8_json->decode($message) } unless ref $message eq 'HASH';
        delete $message->{message} if $message->{site_status} ne 'down';

        $client_shared->{c}->send({
                json => {
                    website_status => {%{$client_shared->{website_status}}, %$message},
                    echo_req       => $client_shared->{echo},
                    msg_type       => 'website_status'
                }});
    }
    return;
}

sub ticks {
    my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};
    my @symbols = (ref $args->{ticks}) ? @{$args->{ticks}} : ($args->{ticks});
    foreach my $symbol (@symbols) {
        $c->call_rpc({
                args        => $args,
                method      => 'ticks',
                msg_type    => 'tick',
                symbol      => $symbol,
                call_params => {
                    symbol => $symbol,
                },
                success => sub {
                    my ($c, undef, $req_storage) = @_;
                    $req_storage->{id} = _feed_channel_subscribe($c, $req_storage->{symbol}, 'tick', $req_storage->{args});
                },
                response => sub {
                    my ($rpc_response, $api_response, $req_storage) = @_;
                    return $api_response if $rpc_response->{error};
                    unless ($req_storage->{id}) {
                        $api_response =
                            $c->new_error('tick', 'AlreadySubscribed', $c->l('You are already subscribed to [_1]', $req_storage->{symbol}));
                    }
                    undef $api_response unless $api_response->{error};    # Don't return anything if subscribed ok
                    return $api_response;
                }
            });
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
        # Here $c might be undef and will generate an error during shutdown of websockets. Here is Tom's comment:
        #as far as I can see, the issue here is that we process a Redis response just after the websocket connection has closed.
        #In this case, we're already in global destruction and there just happens to be a race,
        #one that we might be able to fix by explicitly closing the Redis connection as one of the first steps during shutdown.
        #
        #Explicitly closing the Redis connection wouldn't do anything to help a race between websocket close and Redis response during normal operation, of course,
        #but until we have a failing test case which demonstrates that, I don't think it's worth spending too much time on.
        return if (!$c || !$c->tx);
        $c->call_rpc({
                args            => $args,
                origin_args     => $req_storage->{origin_args},
                method          => 'ticks_history',
                rpc_response_cb => sub {
                    my ($c, $rpc_response, $req_storage) = @_;
                    return if (!$c || !$c->tx);
                    my $args = $req_storage->{args};
                    if (exists $rpc_response->{error}) {
                        # cancel subscription if response has error
                        _feed_channel_unsubscribe($c, $args->{ticks_history}, $publish, $args->{req_id});
                        return $c->new_error('ticks_history', $rpc_response->{error}->{code}, $c->l($rpc_response->{error}->{message_to_client}));
                    }

                    my $channel = $args->{ticks_history} . ';' . $publish;
                    $channel .= ";" . $args->{req_id} if exists $args->{req_id};
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

                    my $feed_channel_type = $c->stash('feed_channel_type') // {};
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
        if (not _feed_channel_subscribe($c, $args->{ticks_history}, $publish, $args, $callback, 1)) {
            return $c->new_error('ticks_history', 'AlreadySubscribed', $c->l('You are already subscribed to [_1]', $args->{ticks_history}));
        }
    } else {
        &$callback;
    }

    return;
}

sub process_realtime_events {
    my ($shared_info, $msg, $chan) = @_;
    my $payload = $utf8_json->decode($msg);

    # pick the per-user controller to send-back notifications to
    # related users only
    my $c = $shared_info->{'c'};

    my $feed_channels_type = $c->stash('feed_channel_type')  // {};
    my $feed_channel_cache = $c->stash('feed_channel_cache') // {};

    foreach my $channel (keys %{$feed_channels_type}) {
        my ($symbol, $type, $req_id) = split(";", $channel);
        my $arguments = $feed_channels_type->{$channel}->{args};
        my $cache     = $feed_channels_type->{$channel}->{cache};

        if ($type eq 'tick' and $payload->{symbol} eq $symbol) {
            unless ($c->tx) {
                _feed_channel_unsubscribe($c, $symbol, $type, $req_id);
                next;
            }

            my $tick = {
                id     => $feed_channels_type->{$channel}->{uuid},
                symbol => $symbol,
                epoch  => $payload->{epoch},
                quote  => $payload->{spot},
                bid    => $payload->{bid},
                ask    => $payload->{ask}};

            if ($cache) {
                $feed_channel_cache->{$channel}->{$payload->{epoch}} = $tick;
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
        } elsif ($payload->{symbol} eq $symbol) {
            unless ($c->tx) {
                _feed_channel_unsubscribe($c, $symbol, $type, $req_id);
                next;
            }

            my ($open, $high, $low, $close) = $payload->{ohlc} =~ /$type:([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+);?/;
            my $epoch = $payload->{epoch};
            my $ohlc  = {
                id        => $feed_channels_type->{$channel}->{uuid},
                epoch     => $epoch,
                open_time => ($type and looks_like_number($type))
                ? $epoch - $epoch % $type
                : $epoch - $epoch % 60,    #defining default granularity
                symbol      => $symbol,
                granularity => $type,
                open        => $open,
                high        => $high,
                low         => $low,
                close       => $close,
            };

            if ($cache) {
                $feed_channel_cache->{$channel}->{$epoch} = $ohlc;
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

    return;
}

sub _feed_channel_subscribe {
    my ($c, $symbol, $type, $args, $callback, $cache) = @_;

    my $channel_name = "FEED::$symbol";
    my $invoke_cb;
    my $shared_info = shared_redis->{shared_info}{$channel_name} //= {};

    # we use stash hash ( = stash hash address) as user id,
    # as we don't want to deal with user_login, user_id, user_email
    # unauthorized users etc.
    weaken($shared_info->{$c + 0}{c} = $c);

    # check that the current worker is already (globally) subscribed
    if (!$shared_info->{symbols}->{$symbol}) {
        push @{$shared_info->{callbacks}}, $callback if ($callback);
        warn("To many callbacks in queue ($symbol), possible redis connection issue")
            if (@{$shared_info->{callbacks} // []} > 1000);

        shared_redis->subscribe(
            [$channel_name],
            sub {
                $shared_info->{symbols}->{$symbol} = 1;
                my $callbacks = $shared_info->{callbacks} // [];
                while (my $cb = shift(@$callbacks)) {
                    # might be an case where client already disconnected before
                    # successfull redis subscription
                    try {
                        $cb->();
                    }
                    catch {
                        warn("callback invocation error during redis subscription to $symbol: $_");
                    };
                }
            }) unless ${^GLOBAL_PHASE} eq 'DESTRUCT';
    } elsif ($callback) {
        $invoke_cb = 1;
    }

    my $feed_channel_type  = $c->stash('feed_channel_type')  // {};
    my $feed_channel_cache = $c->stash('feed_channel_cache') // {};

    my $key    = "$symbol;$type";
    my $req_id = $args->{req_id};
    $key .= ";$req_id" if $req_id;

    # already subscribed
    if (exists $feed_channel_type->{$key}) {
        return;
    }

    my $uuid = _generate_uuid_string();
    ### TODO: Move to shared_info
    $feed_channel_type->{$key}->{args}  = $args if $args;
    $feed_channel_type->{$key}->{uuid}  = $uuid;
    $feed_channel_type->{$key}->{cache} = $cache || 0;

    $c->stash('feed_channel_type',  $feed_channel_type);
    $c->stash('feed_channel_cache', $feed_channel_cache);

    $callback->() if ($invoke_cb);

    return $uuid;
}

sub _feed_channel_unsubscribe {
    my ($c, $symbol, $type, $req_id) = @_;

    my $shared_info = shared_redis->{shared_info}{"FEED::$symbol"};

    my $per_user_info = $shared_info->{$c + 0} //= {};

    my $feed_channel_type  = $c->stash('feed_channel_type')  // {};
    my $feed_channel_cache = $c->stash('feed_channel_cache') // {};

    my $key = "$symbol;$type";
    $key .= ";$req_id" if $req_id;

    my $args = $feed_channel_type->{$key}->{args};
    my $uuid = $feed_channel_type->{$key}->{uuid};
    delete $feed_channel_type->{$key};
    # delete cache on unsubscribe
    delete $feed_channel_cache->{$key};

    # as we subscribe to transaction channel for proposal_open_contract so need to forget that also
    transaction_channel($c, 'unsubscribe', $args->{account_id}, $uuid) if $type =~ /^proposal_open_contract:/;

    unless (keys %$feed_channel_type) {    # one connection could have several subscriptions (ticks/candles)
        delete $shared_info->{$c + 0};
        if (!keys %$shared_info) {
            $shared_info->{symbols}->{$symbol} = 0;
            shared_redis->unsubscribe(["FEED::$symbol"], sub { });
        }
    }

    return $uuid;
}

sub transaction_channel {
    my ($c, $action, $account_id, $type, $args, $contract_id) = @_;
    $contract_id = $args->{contract_id} // $contract_id;
    my $uuid;

    my $redis = shared_redis;
    ### TODO: Move to redis instance shared_info
    my $channel = $c->stash('transaction_channel');
    my $already_subscribed = $channel ? exists $channel->{$type} : undef;

    if ($action) {
        my $channel_name = 'TXNUPDATE::transaction_' . $account_id;
        if ($action eq 'subscribe' and not $already_subscribed) {
            $uuid = _generate_uuid_string();

            $redis->subscribe([$channel_name], sub { }) unless (keys %$channel);
            $redis->{shared_info}{$channel_name}{$c + 0}{c} = $c;
            ### TODO: Move to shared_info
            $channel->{$type}->{args}        = $args;
            $channel->{$type}->{uuid}        = $uuid;
            $channel->{$type}->{account_id}  = $account_id;
            $channel->{$type}->{contract_id} = $contract_id if $contract_id;
            $c->stash('transaction_channel', $channel);
        } elsif ($action eq 'unsubscribe' and $already_subscribed) {
            delete $channel->{$type};
            unless (%$channel) {
                delete $redis->{shared_info}{$channel_name}{$c + 0};
                delete $c->stash->{transaction_channel};
            }
            # Unsubscribe from redis if there's no listener across connections for the channel
            $redis->unsubscribe([$channel_name], sub { }) if not %{$redis->{shared_info}{$channel_name}};
        }
    }

    return $uuid;
}

sub process_transaction_updates {
    my ($shared_info, $message, $channel_name) = @_;

    my $c       = $shared_info->{c};
    my $channel = $c->stash('transaction_channel');

    return unless $channel;

    my $payload = JSON::MaybeXS->new->decode($message);

    return unless $payload && ref $payload eq 'HASH';

    my $err = $payload->{error} ? $payload->{error}->{code} : undef;
    if (!$c->stash('account_id') || ($err && $err eq 'TokenDeleted')) {
        transaction_channel($c, 'unsubscribe', $channel->{$_}->{account_id}, $_) for keys %{$channel};
        return;
    }
    ### new proposal_open_contract stream after buy
    ### we have to do it here. we have not longcode in payout.
    ### we'll start new bid stream if we have proposal_open_contract subscription and have bought a new contract
    _create_poc_stream($c, $payload) if $payload->{action_type} eq 'buy';

    my $args = {};
    foreach my $type (keys %{$channel}) {
        $args = (exists $channel->{$type}->{args}) ? $channel->{$type}->{args} : {};

        _update_balance($c, $args, $payload, $channel->{$type}->{uuid})
            if $type eq 'balance';

        _update_transaction($c, $args, $payload, $channel->{$type}->{uuid})
            if $type eq 'transaction';

        ### proposal_open_contract stream. Type is UUID
        _close_proposal_open_contract_stream($c, $args, $payload, $channel->{$type}->{contract_id}, $type)
            if $type =~ /\w{8}-\w{4}-\w{4}-\w{4}-\w{12}/;

    }

    return;
}

my %skip_duration_list = map { $_ => 1 } qw(s m h);
my %skip_symbol_list   = map { $_ => 1 } qw(R_100 R_50 R_25 R_75 R_10 RDBULL RDBEAR);
my %skip_type_list     = map { $_ => 1 } qw(CALL PUT DIGITMATCH DIGITDIFF DIGITOVER DIGITUNDER DIGITODD DIGITEVEN);

sub _skip_streaming {
    my $args = shift;

    return 1 if $args->{skip_streaming};
    my $skip_symbols = ($skip_symbol_list{$args->{symbol}}) ? 1 : 0;
    my $atm_contract =
        ($args->{contract_type} =~ /^(CALL|PUT)$/ and not($args->{barrier} or ($args->{proposal_array} and $args->{barriers}))) ? 1 : 0;
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

my $RAND;

BEGIN {
    open $RAND, "<", "/dev/urandom" or die "Could not open /dev/urandom : $!";    ## no critic (InputOutput::RequireBriefOpen)
}

sub _generate_uuid_string {
    local $/ = \16;
    return join "-", unpack "H8H4H4H4H12", (scalar <$RAND> or die "Could not read from /dev/urandom : $!");
}

# POC means proposal_open_contract
sub _create_poc_stream {
    my $c       = shift;
    my $payload = shift;

    my $poc_args = $c->stash('proposal_open_contracts_subscribed');

    if ($poc_args && $payload->{financial_market_bet_id}) {

        $c->call_rpc({
                url         => Binary::WebSocketAPI::Hooks::get_rpc_url($c),
                args        => $poc_args,
                msg_type    => '',
                method      => 'longcode',
                call_params => {
                    token       => $c->stash('token'),
                    short_codes => [$payload->{short_code}],
                    currency    => $payload->{currency_code},
                    language    => $c->stash('language'),
                },
                response => sub {
                    my $rpc_response = shift;

                    $payload->{longcode} = $rpc_response->{longcodes}{$payload->{short_code}};
                    warn "Wrong longcode response: " . encode_json($rpc_response) unless $payload->{longcode};

                    my $uuid = Binary::WebSocketAPI::v3::Wrapper::Pricer::_pricing_channel_for_bid(
                        $c,
                        $poc_args,
                        {
                            shortcode   => $payload->{short_code},
                            currency    => $payload->{currency_code},
                            is_sold     => $payload->{sell_time} ? 1 : 0,
                            contract_id => $payload->{financial_market_bet_id},
                            buy_price   => $payload->{purchase_price},
                            account_id  => $payload->{account_id},
                            longcode => $payload->{longcode} || $payload->{payment_remark},
                            transaction_ids => {buy => $payload->{id}},
                            purchase_time   => Date::Utility->new($payload->{purchase_time})->epoch,
                            sell_price      => undef,
                            sell_time       => undef,
                        });

                    # subscribe to transaction channel as when contract is manually sold we need to cancel streaming
                    transaction_channel($c, 'subscribe', $payload->{account_id}, $uuid, $poc_args, $payload->{financial_market_bet_id})
                        if $uuid;
                    return;
                },
            });

        return 1;
    }
    return 0;
}

sub _update_balance {
    my $c       = shift;
    my $args    = shift;
    my $payload = shift;
    my $id      = shift;

    my $details = {
        msg_type => 'balance',
        $args ? (echo_req => $args) : (),
        balance => {
            ($id ? (id => $id) : ()),
            loginid  => $c->stash('loginid'),
            currency => $c->stash('currency'),
            balance  => formatnumber('amount', $c->stash('currency'), $payload->{balance_after}),
        }};

    $c->send({json => $details}) if $c->tx;
    return;
}

sub _update_transaction {
    my $c       = shift;
    my $args    = shift;
    my $payload = shift;
    my $id      = shift;

    my $details = {
        msg_type => 'transaction',
        $args ? (echo_req => $args) : (),
        transaction => {
            ($id ? (id => $id) : ()),
            balance        => formatnumber('amount', $payload->{currency_code}, $payload->{balance_after}),
            action         => $payload->{action_type},
            amount         => $payload->{amount},
            transaction_id => $payload->{id},
            longcode       => $payload->{payment_remark},
            contract_id    => $payload->{financial_market_bet_id},
            ($payload->{currency_code} ? (currency => $payload->{currency_code}) : ()),
        },
    };

    if (not exists $payload->{referrer_type} or $payload->{referrer_type} ne 'financial_market_bet') {
        $details->{transaction}->{transaction_time} = Date::Utility->new($payload->{payment_time})->epoch;
        $c->send({json => $details});
        return;
    }

    $details->{transaction}->{transaction_time} = Date::Utility->new($payload->{sell_time} || $payload->{purchase_time})->epoch;

    $c->call_rpc({
            url         => Binary::WebSocketAPI::Hooks::get_pricing_rpc_url($c),
            args        => $args,
            msg_type    => 'transaction',
            method      => 'get_contract_details',
            call_params => {
                token           => $c->stash('token'),
                short_code      => $payload->{short_code},
                currency        => $payload->{currency_code},
                language        => $c->stash('language'),
                landing_company => $c->landing_company_name,
            },
            rpc_response_cb => sub {
                my ($c, $rpc_response) = @_;

                if (exists $rpc_response->{error}) {
                    Binary::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
                    return $c->new_error('transaction', $rpc_response->{error}->{code}, $rpc_response->{error}->{message_to_client});
                } else {
                    $details->{transaction}->{purchase_time} = Date::Utility->new($payload->{purchase_time})->epoch
                        if ($payload->{action_type} eq 'sell');
                    $details->{transaction}->{longcode}     = $rpc_response->{longcode};
                    $details->{transaction}->{symbol}       = $rpc_response->{symbol};
                    $details->{transaction}->{display_name} = $rpc_response->{display_name};
                    $details->{transaction}->{date_expiry}  = $rpc_response->{date_expiry};
                    $details->{transaction}->{barrier}      = $rpc_response->{barrier} if exists $rpc_response->{barrier};
                    $details->{transaction}->{high_barrier} = $rpc_response->{high_barrier} if $rpc_response->{high_barrier};
                    $details->{transaction}->{low_barrier}  = $rpc_response->{low_barrier} if $rpc_response->{low_barrier};

                    return $details;
                }
            },
        });
    return;
}

sub _close_proposal_open_contract_stream {
    my ($c, $args, $payload, $contract_id, $uuid) = @_;

    if (    $payload->{action_type} eq 'sell'
        and exists $payload->{financial_market_bet_id}
        and $contract_id
        and $payload->{financial_market_bet_id} eq $contract_id)
    {
        $payload->{sell_time} = Date::Utility->new($payload->{sell_time})->epoch;
        $payload->{uuid}      = $uuid;

        Binary::WebSocketAPI::v3::Wrapper::Pricer::send_proposal_open_contract_last_time($c, $payload, $contract_id, $args);
    }
    return;
}

1;
