package BOM::WebSocketAPI::v2::MarketDiscovery;

use strict;
use warnings;

use Try::Tiny;
use Mojo::DOM;
use BOM::WebSocketAPI::v2::Symbols;
use BOM::WebSocketAPI::v2::System;

use BOM::Market::Underlying;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Contract::Offerings;

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
            symbol       => sub { return $_->symbol },
            feed_license => sub { return $_->feed_license },
            delay_amount => sub { return $_->delay_amount },
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
                print STDERR $ul->{symbol} if $ul->{delay_amount} > 0;
                push @{$submarket->{symbols}},
                    {
                    name         => $ul->{name},
                    symbol       => $ul->{symbol},
                    settlement   => $ul->{settlement} || '',
                    events       => $ul->{events},
                    times        => $ul->{times},
                    feed_license => $ul->{feed_license},
                    delay_amount => $ul->{delay_amount},
                    };
            }
        }
    }
    return {
        msg_type      => 'trading_times',
        trading_times => $trading_times,
    };
}

sub ticks {
    my ($c, $args) = @_;

    my $symbol = $args->{ticks};
    my $ul     = BOM::Market::Underlying->new($symbol)
        or return {
        msg_type => 'tick',
        error    => {
            message => "symbol $symbol invalid",
            code    => "InvalidSymbol"
        }};

    if ($args->{end}) {
        my $style = $args->{style} || ($args->{granularity} ? 'candles' : 'ticks');
        if ($style eq 'ticks') {
            my $ticks = $c->BOM::WebSocketAPI::v2::Symbols::ticks({%$args, ul => $ul});    ## no critic
            my $history = {
                prices => [map { $_->{price} } @$ticks],
                times  => [map { $_->{time} } @$ticks],
            };
            return {
                msg_type => 'history',
                history  => $history
            };
        } elsif ($style eq 'candles') {
            my $sender = sub {
                my $candles = shift;
                my @labeled_candles =
                    map { {'epoch' => $_->[0], 'open' => $_->[1], 'high' => $_->[2], 'low' => $_->[3], 'close' => $_->[4],} } @$candles;

                $c->send({
                        json => {
                            msg_type => 'candles',
                            echo_req => $args,
                            candles  => \@labeled_candles,
                        }});
            };

            if (
                my $watcher = $c->BOM::WebSocketAPI::v2::Symbols::candles({
                        %$args,    ## no critic
                        ul     => $ul,
                        sender => $sender
                    }))
            {
                # keep this reference; otherwise it goes out of scope early and the job will self-destroy.
                push @{$c->stash->{watchers}}, $watcher;
                $c->on(finish => sub { $c->stash->{feeder}->_pg->destroy });
                return;
            }

            return {
                msg_type => 'candles',
                error    => {
                    message => 'invalid candles request',
                    code    => 'InvalidCandlesRequest'
                }};
        } else {
            return {
                msg_type => 'tick',
                error    => {
                    message => "style $style invalid",
                    code    => "InvalidStyle"
                }};
        }
    }
    if ($ul->feed_license eq 'realtime') {
        my $id;
        $id = Mojo::IOLoop->recurring(1 => sub { send_tick($c, $id, $args, $ul) });
        send_tick($c, $id, $args, $ul);

        my $ws_id = $c->tx->connection;
        $c->{ws}{$ws_id}{$id} = {
            started => time(),
            type    => 'ticks',
            epoch   => 0,
        };
        BOM::WebSocketAPI::v2::System::_limit_stream_count($c);

        return 0;
    } else {
        return {
            msg_type => 'tick',
            error    => {
                message => "realtime quotes not available",
                code    => "NoRealtimeQuotes"
            }};
    }
}

sub proposal {
    my ($c, $args) = @_;

    # this is a recurring contract-price watch ("price streamer")
    # p2 is a manipulated copy of p1 suitable for produce_contract.
    my $p2 = prepare_ask($c, $args);
    my $id;
    $id = Mojo::IOLoop->recurring(1 => sub { send_ask($c, $id, {}, $p2) });

    my $ws_id = $c->tx->connection;
    $c->{ws}{$ws_id}{$id} = {
        started => time(),
        type    => 'proposal',
        data    => {%$p2},
    };
    BOM::WebSocketAPI::v2::System::_limit_stream_count($c);

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
    } else {
        $p1->{duration}      //= 15;
        $p1->{duration_unit} //= 's';
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
    $p2{duration} .= delete $p2{duration_unit} unless $p2{date_expiry};

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
                message => "cannot create contract",
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
                message => "cannot validate contract",
                code    => "ContractValidationError"
            }};
    }
    return {
        longcode   => Mojo::DOM->new->parse($contract->longcode)->all_text,
        payout     => $contract->payout,
        ask_price  => sprintf('%.2f', $contract->ask_price),
        bid_price  => sprintf('%.2f', $contract->bid_price),
        spot       => $contract->current_spot,
        spot_time  => $contract->current_tick->epoch,
        date_start => $contract->date_start->epoch,
    };
}

sub send_ask {
    my ($c, $id, $p1, $p2) = @_;
    my $latest = get_ask($c, $p2);
    if ($latest->{error}) {
        Mojo::IOLoop->remove($id);
        my $ws_id = $c->tx->connection;
        delete $c->{ws}{$ws_id}{$id};

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

sub send_tick {
    my ($c, $id, $p1, $ul) = @_;

    my $ws_id = $c->tx->connection;
    my $tick  = $ul->get_combined_realtime;
    if ($tick->{epoch} > ($c->{ws}{$ws_id}{$id}{epoch} || 0)) {
        $c->send({
                json => {
                    msg_type => 'tick',
                    echo_req => $p1,
                    tick     => {
                        id    => $id,
                        epoch => $tick->{epoch},
                        quote => $tick->{quote}}}});

        $c->{ws}{$ws_id}{$id}{epoch} = $tick->{epoch};
    }
    return;
}

1;
