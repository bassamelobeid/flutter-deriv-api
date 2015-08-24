package BOM::WebSocketAPI::MarketDiscovery;

use strict;
use warnings;

use Try::Tiny;
use Mojo::DOM;
use BOM::WebSocketAPI::Symbols;

use BOM::Market::Underlying;
use BOM::Product::ContractFactory qw(produce_contract);

sub ticks {
    my ($c, $args) = @_;

    my $symbol = $args->{ticks};
    my $ul     = BOM::Market::Underlying->new($symbol)
        or return {
        msg_type => 'tick',
        tick     => {
            error => {
                message => "symbol $symbol invalid",
                code    => "InvalidSymbol"
            }}};

    if ($args->{end}) {
        my $style = $args->{style} || ($args->{granularity} ? 'candles' : 'ticks');
        if ($style eq 'ticks') {
            my $ticks = $c->BOM::WebSocketAPI::Symbols::_ticks({%$args, ul => $ul});    ## no critic
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
                $c->send({
                        json => {
                            msg_type => 'candles',
                            echo_req => $args,
                            candles  => $candles
                        }});
            };

            if (
                my $watcher = $c->BOM::WebSocketAPI::Symbols::_candles({
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
                candles  => {
                    error => {
                        message => 'invalid candles request',
                        code    => 'InvalidCandlesRequest'
                    }}};
        } else {
            return {
                msg_type => 'tick',
                tick     => {
                    error => {
                        message => "style $style invalid",
                        code    => "InvalidStyle"
                    }}};
        }
    }
    if ($ul->feed_license eq 'realtime') {
        my $id;
        $id = Mojo::IOLoop->recurring(1 => sub { send_tick($c, $id, $args, $ul) });
        send_tick($c, $id, $args, $ul);
        $c->on(finish => sub { Mojo::IOLoop->remove($id); delete $c->{$id} });
        return 0;
    } else {
        return {
            msg_type => 'tick',
            tick     => {
                error => {
                    message => "realtime quotes not available",
                    code    => "NoRealtimeQuotes"
                }}};
    }
}

sub proposal {
    my ($c, $args) = @_;

    # this is a recurring contract-price watch ("price streamer")
    # p2 is a manipulated copy of p1 suitable for produce_contract.
    my $p2 = prepare_ask($c, $args);
    my $id;
    $id = Mojo::IOLoop->recurring(1 => sub { send_ask($c, $id, {}, $p2) });
    $c->{$id} = $p2;
    send_ask($c, $id, $args, $p2);
    $c->on(finish => sub { Mojo::IOLoop->remove($id); delete $c->{$id} });

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

    $p1->{contract_type} //= 'CALL';
    $p1->{symbol}        //= 'R_100';
    $p1->{basis}         //= 'payout';
    $p1->{amount_val}    //= 10;
    $p1->{currency}      //= 'USD';
    $p1->{date_start}    //= 0;
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
    } else {
        $p2{barrier} //= 'S0P';
        delete $p2{barrier2};
    }

    $p2{underlying}  = delete $p2{symbol};
    $p2{bet_type}    = delete $p2{contract_type};
    $p2{amount_type} = delete $p2{basis};
    $p2{amount}      = delete $p2{amount_val};
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
        delete $c->{$id};
    }
    $c->send({
            json => {
                msg_type => 'proposal',
                echo_req => $p1,
                proposal => {
                    id => $id,
                    %$latest
                }}});
    return;
}

sub send_tick {
    my ($c, $id, $p1, $ul) = @_;
    my $tick = $ul->get_combined_realtime;
    if ($tick->{epoch} > ($c->{$id}{epoch} || 0)) {
        $c->send({
                json => {
                    msg_type => 'tick',
                    echo_req => $p1,
                    tick     => {
                        id    => $id,
                        epoch => $tick->{epoch},
                        quote => $tick->{quote}}}});
        $c->{$id}{epoch} = $tick->{epoch};
    }
    return;
}

1;
