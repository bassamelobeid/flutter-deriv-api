package BOM::WebSocketAPI::v3::MarketDiscovery;

use strict;
use warnings;

use Try::Tiny;
use Mojo::DOM;
use Time::HiRes;
use BOM::WebSocketAPI::v3::Symbols;
use BOM::WebSocketAPI::v3::System;
use Cache::RedisDB;
use JSON;
use List::MoreUtils qw(any none);

use BOM::Market::Registry;
use BOM::Market::Underlying;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Contract::Offerings;
use BOM::Product::Offerings qw(get_offerings_with_filter get_permitted_expiries);
use BOM::Product::Contract::Category;
use Data::UUID;
use BOM::Market::Underlying;

sub trading_times {
    my ($c, $args) = @_;

    my $date = try { Date::Utility->new($args->{trading_times}) } || Date::Utility->new;
    my $tree = BOM::Product::Contract::Offerings->new(date => $date)->decorate_tree(
        markets     => {name => 'name'},
        submarkets  => {name => 'name'},
        underlyings => {
            name         => 'name',
            times        => 'times',
            events       => 'events',
            symbol       => sub { $_->symbol },
            feed_license => sub { $_->feed_license },
            delay_amount => sub { $_->delay_amount },
        });
    my $trading_times = {};
    for my $mkt (@$tree) {
        my $market = {};
        push @{$trading_times->{markets}}, $market;
        $market->{name} = $mkt->{name};
        for my $sbm (@{$mkt->{submarkets}}) {
            my $submarket = {};
            push @{$market->{submarkets}}, $submarket;
            $submarket->{name} = $sbm->{name};
            for my $ul (@{$sbm->{underlyings}}) {
                push @{$submarket->{symbols}},
                    {
                    name       => $ul->{name},
                    symbol     => $ul->{symbol},
                    settlement => $ul->{settlement} || '',
                    events     => $ul->{events},
                    times      => $ul->{times},
                    ($ul->{feed_license} ne 'realtime') ? (feed_license => $ul->{feed_license}) : (),
                    ($ul->{delay_amount} > 0)           ? (delay_amount => $ul->{delay_amount}) : (),
                    };
            }
        }
    }
    return {
        msg_type      => 'trading_times',
        trading_times => $trading_times,
    };
}

sub asset_index {
    my ($c, $args) = @_;

    my $r    = $c->stash('request');
    my $lang = $r->language;

    if (my $r = Cache::RedisDB->get("WS_ASSETINDEX", $lang)) {
        return {
            msg_type    => 'asset_index',
            asset_index => JSON::from_json($r),
        };
    }

    my $asset_index = BOM::Product::Contract::Offerings->new->decorate_tree(
        markets => {
            code => sub { $_->name },
            name => sub { $_->translated_display_name }
        },
        submarkets => {
            code => sub {
                $_->name;
            },
            name => sub {
                $_->translated_display_name;
            }
        },
        underlyings => {
            code => sub {
                $_->symbol;
            },
            name => sub {
                $_->translated_display_name;
            }
        },
        contract_categories => {
            code => sub {
                $_->code;
            },
            name => sub {
                $_->translated_display_name;
            },
            expiries => sub {
                my $underlying = shift;
                my %offered    = %{
                    get_permitted_expiries({
                            underlying_symbol => $underlying->symbol,
                            contract_category => $_->code,
                        })};

                my @times;
                foreach my $expiry (qw(intraday daily tick)) {
                    if (my $included = $offered{$expiry}) {
                        foreach my $key (qw(min max)) {
                            if ($expiry eq 'tick') {
                                # some tick is set to seconds somehow in this code.
                                # don't want to waste time to figure out how it is set
                                my $tick_count = (ref $included->{$key}) ? $included->{$key}->seconds : $included->{$key};
                                push @times, [$tick_count, $tick_count . 't'];
                            } else {
                                $included->{$key} = Time::Duration::Concise::Localize->new(
                                    interval => $included->{$key},
                                    locale   => $r->language
                                ) unless (ref $included->{$key});
                                push @times, [$included->{$key}->seconds, $included->{$key}->as_concise_string];
                            }
                        }
                    }
                }
                @times = sort { $a->[0] <=> $b->[0] } @times;
                return +{
                    min => $times[0][1],
                    max => $times[-1][1],
                };
            },
        },
    );

    ## remove obj for json encode
    my @data;
    for my $market (@$asset_index) {
        delete $market->{$_} for (qw/obj children/);
        for my $submarket (@{$market->{submarkets}}) {
            delete $submarket->{$_} for (qw/obj parent_obj children parent/);
            for my $ul (@{$submarket->{underlyings}}) {
                delete $ul->{$_} for (qw/obj parent_obj children parent/);
                for (@{$ul->{contract_categories}}) {
                    $_ = [$_->{code}, $_->{name}, $_->{expiries}->{min}, $_->{expiries}->{max}];
                }
                my $x = [$ul->{code}, $ul->{name}, $ul->{contract_categories}];
                push @data, $x;
            }
        }
    }

    # set cache
    Cache::RedisDB->set("WS_ASSETINDEX", $lang, JSON::to_json([@data]), 3600);

    return {
        msg_type    => 'asset_index',
        asset_index => [@data],
    };
}

sub ticks {
    my ($c, $args) = @_;

    my @symbols = (ref $args->{ticks}) ? @{$args->{ticks}} : ($args->{ticks});
    my @offerings = get_offerings_with_filter('underlying_symbol');
    foreach my $symbol (@symbols) {
        if (none { $symbol eq $_ } @offerings) {
            return $c->new_error('ticks', 'InvalidSymbol', $c->l("Symbol [_1] invalid", $symbol));
        }
        my $u = BOM::Market::Underlying->new($symbol);

        if ($u->feed_license ne 'realtime') {
            return $c->new_error('ticks', 'NoRealtimeQuotes', $c->l("Realtime quotes not available for [_1]", $symbol));
        }

        if (exists $args->{subscribe} and $args->{subscribe} eq '0') {
            _feed_channel($c, 'unsubscribe', $symbol, 'tick');
        } else {
            my $uuid;
            if (not $uuid = _feed_channel($c, 'subscribe', $symbol, 'tick')) {
                return $c->new_error('ticks', 'AlreadySubscribed', $c->l('You are already subscribed to [_1]', $symbol));
            }
        }

    }

    return;
}

sub ticks_history {
    my ($c, $args) = @_;

    my $symbol = $args->{ticks_history};
    my $symbol_offered = any { $symbol eq $_ } get_offerings_with_filter('underlying_symbol');
    my $ul;
    unless ($symbol_offered and $ul = BOM::Market::Underlying->new($symbol)) {
        return $c->new_error('ticks_history', 'InvalidSymbol', $c->l("Symbol [_1] invalid", $symbol));
    }

    my $style = $args->{style} || ($args->{granularity} ? 'candles' : 'ticks');
    my $publish;
    my $result;
    if ($style eq 'ticks') {
        my $ticks = $c->BOM::WebSocketAPI::v3::Symbols::ticks({%$args, ul => $ul});    ## no critic
        my $history = {
            prices => [map { $_->{price} } @$ticks],
            times  => [map { $_->{time} } @$ticks],
        };
        $result = {
            msg_type => 'history',
            history  => $history
        };
        $publish = 'tick';
    } elsif ($style eq 'candles') {

        my @candles = @{$c->BOM::WebSocketAPI::v3::Symbols::candles({%$args, ul => $ul})};    ## no critic
        if (@candles) {
            $result = {
                msg_type => 'candles',
                candles  => \@candles,
            };
            $publish = $args->{granularity};
        } else {
            return $c->new_error('candles', 'InvalidCandlesRequest', $c->l('Invalid candles request'));
        }
    } else {
        return $c->new_error('ticks_history', 'InvalidStyle', $c->l("Style [_1] invalid", $style));
    }

    if ($args->{subscribe} eq '1' and $ul->feed_license ne 'realtime') {
        return $c->new_error('ticks', 'NoRealtimeQuotes', $c->l('Realtime quotes not available'));
    }

    if ($args->{subscribe} eq '1' and $ul->feed_license eq 'realtime') {
        if (not _feed_channel($c, 'subscribe', $symbol, $publish)) {
            $c->new_error('ticks_history', 'AlreadySubscribed', $c->l('You are already subscribed to [_1]', $symbol));
        }
    }
    if ($args->{subscribe} eq '0') {
        _feed_channel($c, 'unsubscribe', $symbol, $publish);
        return;
    }

    return $result;
}

sub _feed_channel {
    my ($c, $subs, $symbol, $type) = @_;
    my $uuid;

    my $feed_channel      = $c->stash('feed_channel');
    my $feed_channel_type = $c->stash('feed_channel_type');

    my $redis = $c->stash('redis');
    if ($subs eq 'subscribe') {
        if (exists $feed_channel_type->{"$symbol;$type"}) {
            return;
        }
        $uuid = Data::UUID->new->create_str();
        $feed_channel->{$symbol} += 1;
        $feed_channel_type->{"$symbol;$type"}->{args} = $c->stash('args');
        $feed_channel_type->{"$symbol;$type"}->{uuid} = $uuid;
        $redis->subscribe(["FEED::$symbol"], sub { });
    }

    if ($subs eq 'unsubscribe') {
        $feed_channel->{$symbol} -= 1;
        delete $feed_channel_type->{"$symbol;$type"};
        if ($feed_channel->{$symbol} <= 0) {
            $redis->unsubscribe(["FEED::$symbol"], sub { });
            delete $feed_channel->{$symbol};
        }
    }

    $c->stash('feed_channel'      => $feed_channel);
    $c->stash('feed_channel_type' => $feed_channel_type);

    return $uuid;
}

sub process_realtime_events {
    my ($c, $message) = @_;

    my @m = split(';', $message);
    my $feed_channels_type = $c->stash('feed_channel_type');

    foreach my $channel (keys %{$feed_channels_type}) {
        $channel =~ /(.*);(.*)/;
        my $symbol = $1;
        my $type   = $2;

        if ($type eq 'tick' and $m[0] eq $symbol) {
            $c->send({
                    json => {
                        msg_type => 'tick',
                        echo_req => $feed_channels_type->{$channel}->{args},
                        tick     => {
                            id     => $feed_channels_type->{$channel}->{uuid},
                            symbol => $symbol,
                            epoch  => $m[1],
                            quote  => BOM::Market::Underlying->new($symbol)->pipsized_value($m[2])}}}) if $c->tx;
        } elsif ($type =~ /^proposal:/ and $m[0] eq $symbol) {
            send_ask($c, $feed_channels_type->{$channel}->{uuid}, $feed_channels_type->{$channel}->{args}) if $c->tx;
        } elsif ($type =~ /^proposal_open_contract:/ and $m[0] eq $symbol) {
            send_ask($c, $feed_channels_type->{$channel}->{uuid}, $feed_channels_type->{$channel}->{args}) if $c->tx;
        } elsif ($m[0] eq $symbol) {
            my $u = BOM::Market::Underlying->new($symbol);
            $message =~ /;$type:([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+);/;
            $c->send({
                    json => {
                        msg_type => 'ohlc',
                        echo_req => $feed_channels_type->{$channel},
                        ohlc     => {
                            id          => $feed_channels_type->{$channel}->{uuid},
                            epoch       => $m[1],
                            open_time   => $m[1] - $m[1] % $type,
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

sub proposal {
    my ($c, $args) = @_;

    my $symbol_offered = any { $args->{symbol} eq $_ } get_offerings_with_filter('underlying_symbol');
    my $ul;
    unless ($symbol_offered and $ul = BOM::Market::Underlying->new($args->{symbol})) {
        return $c->new_error('ticks_history', 'InvalidSymbol', $c->l("Symbol [_1] invalid", $args->{symbol}));
    }
    my $id = _feed_channel($c, 'subscribe', $args->{symbol}, 'proposal:' . JSON::to_json($args));

    send_ask($c, $id, $args);

    return;
}

sub prepare_ask {
    my $p1 = shift;

    $p1->{date_start} //= 0;
    if ($p1->{date_expiry}) {
        $p1->{fixed_expiry} //= 1;
    }
    my %p2 = %$p1;

    if (defined $p2{barrier} && defined $p2{barrier2}) {
        $p2{low_barrier}  = delete $p2{barrier2};
        $p2{high_barrier} = delete $p2{barrier};
    } elsif ($p1->{contract_type} !~ /^SPREAD/) {
        $p2{barrier} //= 'S0P';
        delete $p2{barrier2};
    }

    $p2{underlying}  = delete $p2{symbol};
    $p2{bet_type}    = delete $p2{contract_type};
    $p2{amount_type} = delete $p2{basis} if exists $p2{basis};
    if ($p2{duration} and not exists $p2{date_expiry}) {
        $p2{duration} .= delete $p2{duration_unit};
    }

    return \%p2;
}

sub get_ask {
    my ($c, $p2) = @_;
    my $app      = $c->app;
    my $log      = $app->log;
    my $contract = try { produce_contract({%$p2}) } || do {
        my $err = $@;
        return {
            error => {
                message => $c->l("Cannot create contract"),
                code    => "ContractCreationFailure"
            }};
    };
    if (!$contract->is_valid_to_buy) {
        if (my $pve = $contract->primary_validation_error) {
            return {
                error => {
                    message => $pve->message_to_client,
                    code    => "ContractBuyValidationError"
                },
                longcode  => Mojo::DOM->new->parse($contract->longcode)->all_text,
                ask_price => sprintf('%.2f', $contract->ask_price),
            };
        }
        $log->error("contract invalid but no error!");
        return {
            error => {
                message => $c->l("Cannot validate contract"),
                code    => "ContractValidationError"
            }};
    }

    my $ask_price = sprintf('%.2f', $contract->ask_price);
    my $display_value = $contract->is_spread ? $contract->buy_level : $ask_price;

    my $response = {
        longcode      => Mojo::DOM->new->parse($contract->longcode)->all_text,
        payout        => $contract->payout,
        ask_price     => $ask_price,
        display_value => $display_value,
        spot          => $contract->current_spot,
        spot_time     => $contract->current_tick->epoch,
        date_start    => $contract->date_start->epoch
    };
    $response->{spread} = $contract->spread if $contract->is_spread;

    return $response;
}

sub send_ask {
    my ($c, $id, $args) = @_;

    my $latest = get_ask($c, prepare_ask($args));
    if ($latest->{error}) {
        BOM::WebSocketAPI::v3::System::forget_one $c, $id;

        my $proposal = {id => $id};
        $proposal->{longcode}  = delete $latest->{longcode}  if $latest->{longcode};
        $proposal->{ask_price} = delete $latest->{ask_price} if $latest->{ask_price};
        $c->send({
                json => {
                    msg_type => 'proposal',
                    echo_req => $args,
                    proposal => $proposal,
                    %$latest
                }});
    } else {
        $c->send({
                json => {
                    msg_type => 'proposal',
                    echo_req => $args,
                    proposal => {
                        id => $id,
                        %$latest
                    }}});
    }
    return;
}

1;
