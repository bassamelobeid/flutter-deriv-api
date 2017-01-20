package Binary::WebSocketAPI::v3::Wrapper::Streamer;

use strict;
use warnings;

use JSON;
use Scalar::Util qw (looks_like_number refaddr weaken);
use List::MoreUtils qw(last_index);
use Date::Utility;

use Binary::WebSocketAPI::v3::Wrapper::Pricer;
use Binary::WebSocketAPI::v3::Wrapper::System;
use Mojo::Redis::Processor;
use JSON::XS qw(encode_json decode_json);
use Time::HiRes qw(gettimeofday);
use utf8;
use Try::Tiny;

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
                    my ($c, $rpc_response, $req_storage) = @_;
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
    my ($shared_info, $message, $chan) = @_;

    my @m = split(';', $message);

    for my $user_id (keys %{$shared_info->{per_user}}) {
        my $per_user_info = $shared_info->{per_user}->{$user_id};
        # pick the per-user controller to send-back notifications to
        # related users only
        my $c = $per_user_info->{'c'};
        if (!$c) {
            delete $shared_info->{per_user}->{$user_id};
            next;
        }

        my $feed_channels_type = $c->stash('feed_channel_type')  // {};
        my $feed_channel_cache = $c->stash('feed_channel_cache') // {};

        foreach my $channel (keys %{$feed_channels_type}) {
            my ($symbol, $type, $req_id) = split(";", $channel);
            my $arguments = $feed_channels_type->{$channel}->{args};
            my $cache     = $feed_channels_type->{$channel}->{cache};

            if ($type eq 'tick' and $m[0] eq $symbol) {
                unless ($c->tx) {
                    _feed_channel_unsubscribe($c, $symbol, $type, $req_id);
                    next;
                }

                my $tick = {
                    id     => $feed_channels_type->{$channel}->{uuid},
                    symbol => $symbol,
                    epoch  => $m[1],
                    quote  => $m[2]};

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
            } elsif ($m[0] eq $symbol) {
                unless ($c->tx) {
                    _feed_channel_unsubscribe($c, $symbol, $type, $req_id);
                    next;
                }

                $message =~ /;$type:([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+);?/;
                my $ohlc = {
                    id        => $feed_channels_type->{$channel}->{uuid},
                    epoch     => $m[1],
                    open_time => ($type and looks_like_number($type))
                    ? $m[1] - $m[1] % $type
                    : $m[1] - $m[1] % 60,    #defining default granularity
                    symbol      => $symbol,
                    granularity => $type,
                    open        => $1,
                    high        => $2,
                    low         => $3,
                    close       => $4
                };

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
    }

    return;
}

sub _feed_channel_subscribe {
    my ($c, $symbol, $type, $args, $callback, $cache) = @_;

    my $channel_name = "FEED::$symbol";
    my $invoke_cb;
    my $shared_info = $c->redis_connections($channel_name);

    # we use stash hash ( = stash hash address) as user id,
    # as we don't want to deal with user_login, user_id, user_email
    # unauthorized users etc.
    my $user_id = refaddr $c->stash;
    my $per_user_info = $shared_info->{per_user}->{$user_id} //= {};

    # check that the current worker is already (globally) subscribed
    if (!$shared_info->{symbols}->{$symbol}) {
        push @{$shared_info->{callbacks}}, $callback if ($callback);
        warn("To many callbacks in queue ($symbol), possible redis connection issue")
            if (@{$shared_info->{callbacks} // []} > 1000);

        $c->shared_redis->subscribe(
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

    # keep the controller to send back redis notifications
    $per_user_info->{'c'} = $c;
    # let's avoid cycles, which lead to memory leaks
    weaken $per_user_info->{'c'};
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

    my $shared_info   = $c->redis_connections("FEED::$symbol");
    my $user_id       = refaddr $c->stash;
    my $per_user_info = $shared_info->{per_user}->{$user_id} //= {};

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
    _transaction_channel($c, 'unsubscribe', $args->{account_id}, $uuid) if $type =~ /^proposal_open_contract:/;

    delete $shared_info->{per_user}->{$user_id};
    if (!keys %{$shared_info->{per_user} // {}}) {
        $shared_info->{symbols}->{$symbol} = 0;
        $c->shared_redis->unsubscribe(["FEED::$symbol"], sub { });
    }

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
            $uuid = _generate_uuid_string();
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
            if (    $payload
                and exists $payload->{error}
                and exists $payload->{error}->{code}
                and $payload->{error}->{code} eq 'TokenDeleted')
            {
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
                        $details->{$type}->{balance}  = sprintf('%.2f', $payload->{balance_after});
                        $c->send({json => $details}) if $c->tx;
                    } elsif ($type eq 'transaction') {
                        $details->{$type}->{balance}        = sprintf('%.2f', $payload->{balance_after});
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
                                        my ($c, $rpc_response, $req_storage) = @_;

                                        if (exists $rpc_response->{error}) {
                                            Binary::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
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
                        $payload->{sell_time} = Date::Utility->new($payload->{sell_time})->epoch;
                        $payload->{uuid}      = $type;

                        # send proposal details last time
                        Binary::WebSocketAPI::v3::Wrapper::Pricer::send_proposal_open_contract_last_time($c, $payload);
                    }
                } elsif ($channel and exists $channel->{$type}->{account_id}) {
                    _transaction_channel($c, 'unsubscribe', $channel->{$type}->{account_id}, $type);
                }
            }
        }
    }
    return;
}

my %skip_duration_list = map { $_ => 1 } qw(s m h);
my %skip_symbol_list   = map { $_ => 1 } qw(R_100 R_50 R_25 R_75 R_10 RDBULL RDBEAR);
my %skip_type_list     = map { $_ => 1 } qw(CALL PUT DIGITMATCH DIGITDIFF DIGITOVER DIGITUNDER DIGITODD DIGITEVEN);

sub _skip_streaming {
    my $args = shift;

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

1;
