package Binary::WebSocketAPI::v3::Wrapper::Streamer;

use strict;
use warnings;

no indirect;

use Try::Tiny;
use Date::Utility;
use Encode;
use Time::HiRes qw(gettimeofday);
use List::MoreUtils qw(last_index);
use JSON::MaybeXS;
use Scalar::Util qw (looks_like_number refaddr weaken);
use List::Util qw(any);
use Format::Util::Numbers qw(formatnumber);

use Binary::WebSocketAPI::v3::Wrapper::Pricer;
use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Instance::Redis qw(ws_redis_master);
use Binary::WebSocketAPI::v3::Subscription::Feed;

my $json = JSON::MaybeXS->new;

sub get_status_msg {
    my ($c, $status_code) = @_;

    my %status_msg = (
        release_due => $c->l('We are updating our site in a short while. Some services may be temporarily unavailable.'),
        suspended   => $c->l('Sorry, but trading is unavailable until further notice due to an unexpected error. Please try again later.'),
        feed_issues => $c->l(
            'We are having an issue with one or more of our data feeds. We are working to resolve the issue but some markets may be unavailable for the time being.'
        ),
        mt5_issues     => $c->l('Sorry, but we are having a technical issue with our MT5 platform. Trading is unavailable for the time being.'),
        cashier_issues => $c->l(
            'Sorry, but we are experiencing a technical issue with our Cashier. Your funds are safe but deposits and withdrawals are unavailable for the time being.'
        ),
        unstable => $c->l(
            'We are experiencing an unusually high load on our system. Some features and services may be unstable or temporarily unavailable. We hope to resolve this issue as soon as we can.'
        ),
    );

    return $status_msg{$status_code};
}

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
                    my ($rpc_response, $api_response, $req_storage) = @_;
                    return $api_response if $rpc_response->{error};

                    my $website_status = {};
                    my $connection_id  = $c + 0;
                    my $uuid           = $shared_info->{broadcast_notifications}{$connection_id}->{uuid};

                    if ($req_storage->{args}->{subscribe}) {
                        if ($uuid) {
                            return $c->new_error('website_status', 'AlreadySubscribed',
                                $c->l('You are already subscribed to [_1]', 'website_status'));
                        } else {
                            $uuid = Binary::WebSocketAPI::v3::Subscription::generate_uuid_string();
                        }

                        $shared_info->{broadcast_notifications}{$connection_id}{'c'}            = $c;
                        $shared_info->{broadcast_notifications}{$connection_id}{echo}           = $args;
                        $shared_info->{broadcast_notifications}{$connection_id}{website_status} = $rpc_response;
                        $shared_info->{broadcast_notifications}{$connection_id}{uuid}           = $uuid;

                        Scalar::Util::weaken($shared_info->{broadcast_notifications}{$connection_id}{'c'});
                    } else {
                        $uuid = undef;
                    }

                    ### to config
                    my $current_state = ws_redis_master()->get("NOTIFY::broadcast::state");
                    $rpc_response->{clients_country} //= '';
                    $website_status->{$_} = $rpc_response->{$_}
                        for qw|api_call_limits clients_country supported_languages terms_conditions_version currencies_config|;

                    $current_state = eval { $json->decode(Encode::decode_utf8($current_state)) }
                        if $current_state && !ref $current_state;
                    $website_status->{site_status} = $current_state->{site_status} // 'up';
                    $website_status->{message} = get_status_msg($c, $current_state->{message}) // '' if $current_state->{message};

                    return {
                        website_status => $website_status,
                        msg_type       => 'website_status',
                        #websocket test framework sets ws status in redis with a passthrough and expects to read it back.
                        +($current_state->{passthrough} ? (passthrough => $current_state->{passthrough}) : ()),
                        ($uuid ? (subscription => {id => $uuid}) : ()),
                    };
                }
            });
    };

    if ($args->{subscribe} && !$shared_info->{broadcast_notifications}{$c + 0}->{uuid}) {
        $redis->subscribe([$channel_name], $callback);
        return;
    }

    $callback->();
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
        my $c = $client_shared->{c} or return;
        unless (defined $c->tx) {
            delete $shared->{broadcast_notifications}{$c_addr};
            ws_redis_master->unsubscribe([$channel])
                if (scalar keys %{$shared->{broadcast_notifications}}) == 0 && $channel;
            next;
        }

        unless ($is_on_key) {
            $is_on_key = "NOTIFY::broadcast::is_on";    ### TODO: to config
            return unless ws_redis_master()->get($is_on_key);    ### Need 1 for continuing
        }

        $message = eval { $json->decode(Encode::decode_utf8($message)) } unless ref $message eq 'HASH';

        # Make a local (shallow) copy of the status here so that its
        # message can be correctly localized depending on the connection
        my $website_status = {%{$client_shared->{website_status}}};
        $website_status->{site_status} = $message->{site_status};
        $website_status->{message} = get_status_msg($c, $message->{message}) if $message->{message};

        my $uuid = $client_shared->{uuid};

        $c->send({
                json => {
                    website_status => $website_status,
                    echo_req       => $client_shared->{echo},
                    #websocket test framework publishes ws status with a passthrough and expects to read it back.
                    ($message->{passthrough} ? (passthrough => $message->{passthrough}) : ()),
                    msg_type => 'website_status',
                    ($uuid ? (subscription => {id => $uuid}) : ()),
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
                    my ($c, $api_response, $req_storage) = @_;
                    $req_storage->{id} = _feed_channel_subscribe($c, $req_storage->{symbol}, 'tick', $req_storage->{args});
                },
                response => sub {
                    my ($rpc_response, $api_response, $req_storage) = @_;
                    return $api_response if $rpc_response->{error};

                    if ($req_storage->{id}) {
                        $api_response->{subscription}->{id} = $req_storage->{id};
                    } else {
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

    # Remove this first, since { granularity: 0 } with no style should be
    # treated as a request for ticks
    delete $args->{granularity} unless $args->{granularity};
    my $style = $args->{style};
    $style //= $args->{granularity} ? 'candles' : 'ticks';

    my $publish;
    if ($style eq 'ticks') {
        $publish = 'tick';
    } elsif ($style eq 'candles') {
        # Default missing and 0 cases to 60 (one-minute candles)
        $args->{granularity} //= 60;
        # The granularity parameter is documented as only being relevant for candles, so we limit the error check
        # to the candles case
        return $c->new_error('ticks_history', "InvalidGranularity", $c->l('Granularity is not valid'))
            unless any { $_ == $args->{granularity} } qw(60 120 180 300 600 900 1800 3600 7200 14400 28800 86400);
        $publish = $args->{granularity};
    } else {
        return $c->new_error('ticks_history', "InvalidStyle", $c->l('Style [_1] invalid', $style));
    }

    my $callback = sub {
        my $worker = shift;
        # Here $c might be undef and will generate an error during shutdown of websockets. Here is Tom's comment:
        # as far as I can see, the issue here is that we process a Redis response just after the websocket connection has closed.
        # In this case, we're already in global destruction and there just happens to be a race,
        # one that we might be able to fix by explicitly closing the Redis connection as one of the first steps during shutdown.
        #
        # Explicitly closing the Redis connection wouldn't do anything to help a race between websocket close and Redis response during normal operation, of course,
        # but until we have a failing test case which demonstrates that, I don't think it's worth spending too much time on.
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
                        $worker->unregister if $worker;
                        return $c->new_error('ticks_history', $rpc_response->{error}->{code}, $c->l($rpc_response->{error}->{message_to_client}));
                    }

                    my $real_worker = $worker || Binary::WebSocketAPI::v3::Subscription::Feed->new(
                        c          => $c,
                        type       => $publish,
                        args       => $args,
                        symbol     => $args->{ticks_history},
                        cache_only => 0,
                    )->already_registered;
                    my $cache = $real_worker ? $real_worker->cache : undef;
                    # check for cached data
                    if ($cache and scalar(keys %$cache)) {
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
                            if (@$candles) {
                                my @matches = grep { $_ < $candles->[-1]->{epoch} } keys %$cache;
                                delete @$cache{@matches};
                            }

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

                    }

                    if ($worker) {
                        # remove the cache_only flag which was set during subscription
                        # TODO to viewer: should we delete it if we used cache directly but not do a subscription? that is, we run callback directly, without subscribing ? I guess we shouldn't delete it
                        $worker->clear_cache;
                        $worker->cache_only(0);

                        my $uuid = $worker->uuid();
                        $rpc_response->{data}->{subscription}->{id} = $uuid if $uuid;
                    }

                    return {
                        msg_type => $rpc_response->{type},
                        %{$rpc_response->{data}}};
                }
            });
    };

    # subscribe first with flag of cache_only passed as 1 to indicate to cache the feed data
    if ($args->{subscribe}) {
        if (not _feed_channel_subscribe($c, $args->{ticks_history}, $publish, $args, $callback, 1)) {
            return $c->new_error('ticks_history', 'AlreadySubscribed', $c->l('You are already subscribed to [_1]', $args->{ticks_history}));
        }
    } else {
        $callback->();
    }

    return;
}

sub _feed_channel_subscribe {
    my ($c, $symbol, $type, $args, $callback, $cache_only) = @_;

    my $worker = Binary::WebSocketAPI::v3::Subscription::Feed->new(
        c          => $c,
        type       => $type,
        args       => $args,
        symbol     => $symbol,
        cache_only => $cache_only || 0,
    );

    return if ($worker->already_registered);
    $worker->register;
    my $uuid = $worker->uuid();
    $worker->subscribe($callback);
    return $uuid;
}

1;
