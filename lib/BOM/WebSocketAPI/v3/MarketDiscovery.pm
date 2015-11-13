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
use List::MoreUtils qw(any);

use BOM::Platform::Context qw(request localize);
use BOM::Market::Registry;
use BOM::Market::Underlying;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Contract::Offerings;
use BOM::Product::Offerings qw(get_offerings_with_filter get_permitted_expiries);
use BOM::Product::Contract::Category;
use BOM::Feed::Dictator::Client;

sub trading_times {
    my ($c, $args) = @_;

    BOM::Platform::Context::request($c->stash('request'));

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

    BOM::Platform::Context::request($c->stash('request'));

    my $request = $c->stash('request');
    my $lang    = $request->language;

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
                                    locale   => BOM::Platform::Context::request()->language
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

    my $symbol = $args->{ticks};
    my $symbol_offered = any { $symbol eq $_ } get_offerings_with_filter('underlying_symbol');
    my $ul;
    unless ($symbol_offered and $ul = BOM::Market::Underlying->new($symbol)) {
        return $c->new_error('ticks', 'InvalidSymbol', localize("Symbol [_1] invalid", $symbol));
    }

    if ($ul->feed_license eq 'realtime') {
        my ($dictator_client, $id);

        my $data = {
            type    => 'ticks',
            cleanup => sub {
                my $reason = shift;

                $dictator_client && $dictator_client->stop;
                $c->send({
                        json => $c->new_error(
                            'ticks',
                            'EndOfTickStream',
                            localize('This tick stream was canceled due to resource limitations'),
                            {
                                id     => $id,
                                symbol => $symbol,
                            })}) if $reason;
            },
        };

        $id = BOM::WebSocketAPI::v3::System::limit_stream_count($c, $data);

        $dictator_client = BOM::Feed::Dictator::Client->new(
            $ENV{TEST_DICTATOR_HOST} ? (host => $ENV{TEST_DICTATOR_HOST}) : (),
            $ENV{TEST_DICTATOR_PORT} ? (port => $ENV{TEST_DICTATOR_PORT}) : (),
            symbol     => $symbol,
            start_time => time,
            on_message => sub {
                my $tick = shift;

                if (not $tick or ref($tick) eq 'HASH' and exists $tick->{error}) {
                    $c->send({
                            json => $c->new_error(
                                'ticks',
                                'EndOfTickStream',
                                localize('This tick stream has been disrupted. Please try again later.'),
                                {
                                    id     => $id,
                                    symbol => $symbol,
                                })});
                    BOM::WebSocketAPI::v3::System::forget_one $c, $id;
                    return;
                }

                $tick = [$tick] unless ref($tick) eq 'ARRAY';

                for (@$tick) {
                    $c->send({
                            json => {
                                msg_type => 'tick',
                                echo_req => $args,
                                tick     => {
                                    id    => $id,
                                    epoch => $_->{epoch},
                                    quote => $_->{quote}}}});
                }
            });

        return 0;
    } else {
        return $c->new_error('ticks', 'NoRealtimeQuotes', localize('Realtime quotes not available'));
    }
}

sub ticks_history {
    my ($c, $args) = @_;

    my $symbol = $args->{ticks_history};
    my $symbol_offered = any { $symbol eq $_ } get_offerings_with_filter('underlying_symbol');
    my $ul;
    unless ($symbol_offered and $ul = BOM::Market::Underlying->new($symbol)) {
        return $c->new_error('ticks_history', 'InvalidSymbol', localize("Symbol [_1] invalid", $symbol));
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
            return $c->new_error('candles', 'InvalidCandlesRequest', localize('Invalid candles request'));
        }
    } else {
        return $c->new_error('ticks_history', 'InvalidStyle', localize("Style [_1] invalid", $style));
    }

    if ($args->{subscribe} eq '1' and $ul->feed_license ne 'realtime') {
        return $c->new_error('ticks', 'NoRealtimeQuotes', localize('Realtime quotes not available'));
    }
    if ($args->{subscribe} eq '1' and $ul->feed_license eq 'realtime') {
        $c->stash->{feed_channels}->{"$symbol;$publish"} = 1;
    }
    if ($args->{subscribe} eq '0') {
        delete $c->stash->{feed_channels}->{"$symbol;$publish"};
    }

    my $redis         = $c->stash('redis');
    my $feed_channels = $c->stash('feed_channels');

    if (scalar keys %{$feed_channels} > 0) {
        $redis->subscribe(["FEED::$symbol"], sub { });
    } else {
        $redis->unsubscribe(["FEED::$symbol"], sub { });
    }
    return $result;
}

sub send_realtime_ticks {
    my ($c, $message) = @_;

    my @m = split(';', $message);
    my $feed_channels = $c->stash('feed_channels');

    foreach my $channel (keys %{$feed_channels}) {
        $channel =~ /(.*);(.*)/;
        my $symbol      = $1;
        my $granularity = $2;

        if ($granularity eq 'tick' and $m[0] eq $symbol) {
            $c->send({
                    json => {
                        msg_type => 'tick',
                        echo_req => $c->stash('args'),
                        tick     => {
                            symbol => $symbol,
                            epoch  => $m[1],
                            quote  => $m[2]}}});
        } elsif ($m[0] eq $symbol) {
            $message =~ /;$granularity:([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+);/;
            $c->send({
                    json => {
                        msg_type => 'ohlc',
                        echo_req => $c->stash('args'),
                        ohlc  => {
                            epoch       => $symbol,
                            granularity => $granularity,
                            open        => $1,
                            high        => $2,
                            low         => $3,
                            close       => $4
                        }}});
        }
    }

    return 0;
}

sub proposal {
    my ($c, $args) = @_;

    # this is a recurring contract-price watch ("price streamer")
    # p2 is a manipulated copy of p1 suitable for produce_contract.
    my $p2 = prepare_ask($c, $args);
    my $id;
    $id = Mojo::IOLoop->recurring(
        1 => sub {
            send_ask($c, $id, $args, $p2);
        });

    BOM::WebSocketAPI::v3::System::limit_stream_count(
        $c,
        {
            id      => $id,
            type    => 'proposal',
            data    => {%$p2},
            cleanup => sub {
                my $reason = shift;

                Mojo::IOLoop->remove($id);
                $c->send({
                        json => $c->new_error(
                            'ticks',
                            'EndOfStream',
                            localize('This stream has been canceled due to resource limitations'),
                            {
                                id => $id,
                            })}) if $reason;
            },
        });

    send_ask($c, $id, $args, $p2);

    return;
}

sub prepare_ask {
    my ($c, $p1) = @_;

    my $app = $c->app;
    my $log = $app->log;

    $log->debug("prepare_ask got p1 " . $c->dumper($p1));

    # this has two deliverables:
    # 1) apply default values inline to the given $p1,
    # 2) return a manipulated copy suitable for produce_contract

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
        $log->info("contract creation failure: $err");
        return {
            error => {
                message => localize("Cannot create contract"),
                code    => "ContractCreationFailure"
            }};
    };
    if (!$contract->is_valid_to_buy) {
        if (my $pve = $contract->primary_validation_error) {
            $log->error("primary error: " . $pve->message);
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
                message => localize("Cannot validate contract"),
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
    my ($c, $id, $p1, $p2) = @_;

    BOM::Platform::Context::request($c->stash('request'));

    my $latest = get_ask($c, $p2);
    if ($latest->{error}) {
        BOM::WebSocketAPI::v3::System::forget_one $c, $id;

        my $proposal = {id => $id};
        $proposal->{longcode}  = delete $latest->{longcode}  if $latest->{longcode};
        $proposal->{ask_price} = delete $latest->{ask_price} if $latest->{ask_price};
        $c->send({
                json => {
                    msg_type => 'proposal',
                    echo_req => $p1,
                    proposal => $proposal,
                    %$latest
                }});
    } else {
        $c->send({
                json => {
                    msg_type => 'proposal',
                    echo_req => $p1,
                    proposal => {
                        id => $id,
                        %$latest
                    }}});
    }
    return;
}

1;
