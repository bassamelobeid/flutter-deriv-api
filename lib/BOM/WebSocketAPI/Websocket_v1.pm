package BOM::WebSocketAPI::Websocket_v1;

use Mojo::Base 'BOM::WebSocketAPI::BaseController';

use Mojo::DOM;

use BOM::Platform::Client;
use BOM::Product::Transaction;
use BOM::Product::Contract::Finder;
use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);

use BOM::WebSocketAPI::Symbols;
use BOM::WebSocketAPI::Offerings;
use BOM::WebSocketAPI::Authorize;
use BOM::WebSocketAPI::ContractDiscovery;
use BOM::WebSocketAPI::System;

my $DOM = Mojo::DOM->new;

sub ok {
    my $c      = shift;
    my $source = 1;       # check http origin here
    $c->stash(source => 1);
    return 1;
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
    my $app = $c->app;
    my $log = $app->log;
    # $log->debug("pricing with p2 " . $c->dumper($p2));
    my $contract = eval { produce_contract({%$p2}) } || do {
        my $err = $@;
        $log->info("contract creation failure: $err");
        return {error => "cannot create contract"};
    };
    if (!$contract->is_valid_to_buy) {
        if (my $pve = $contract->primary_validation_error) {
            $log->error("primary error: " . $pve->message);
            return {error => $pve->message_to_client};
        }
        $log->error("contract invalid but no error!");
        return {error => "cannot validate contract"};
    }
    return {
        longcode   => $DOM->parse($contract->longcode)->all_text,
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
    my $latest = $c->get_ask($p2);
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

sub prepare_bid {
    my ($c, $p1) = @_;
    my $app      = $c->app;
    my $log      = $app->log;
    my $fmb      = delete $p1->{fmb};
    my $currency = $fmb->account->currency_code;
    my $contract = produce_contract($fmb->short_code, $currency);
    %$p1 = (
        fmb_id        => $fmb->id,
        purchase_time => $fmb->purchase_time->epoch,
        symbol        => $fmb->underlying_symbol,
        payout        => $fmb->payout_price,
        buy_price     => $fmb->buy_price,
        date_start    => $fmb->start_time->epoch,
        expiry_time   => $fmb->expiry_time->epoch,
        contract_type => $fmb->bet_type,
        currency      => $currency,
        longcode      => $DOM->parse($contract->longcode)->all_text,
    );
    return {
        fmb      => $fmb,
        contract => $contract,
    };
}

sub get_bid {
    my ($c, $p2) = @_;
    my $app = $c->app;
    my $log = $app->log;

    my @similar_args = ($p2->{contract}, {priced_at => 'now'});
    my $contract = eval { make_similar_contract(@similar_args) } || do {
        my $err = $@;
        $log->info("contract for sale creation failure: $err");
        return {error => "cannot create sell contract"};
    };
    if (!$contract->is_valid_to_sell) {
        $log->error("primary error: " . $contract->primary_validation_error->message);
        return {error => $contract->primary_validation_error->message_to_client};
    }

    return {
        ask_price => sprintf('%.2f', $contract->ask_price),
        bid_price => sprintf('%.2f', $contract->bid_price),
        spot      => $contract->current_spot,
        spot_time => $contract->current_tick->epoch,
    };
}

sub send_bid {
    my ($c, $id, $p0, $p1, $p2) = @_;
    my $latest = $c->get_bid($p2);
    if ($latest->{error}) {
        Mojo::IOLoop->remove($id);
        delete $c->{$id};
        delete $c->{fmb_ids}{$p2->{fmb}->id};
    }
    $c->send({
            json => {
                msg_type  => 'portfolio',
                echo_req  => $p0,
                portfolio => {
                    id => $id,
                    %$p1,
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

sub _authorize_error {
    my ($c, $p1, $msg_type) = @_;
    $c->send({
            json => {
                msg_type  => $msg_type,
                echo_req  => $p1,
                $msg_type => {
                    error => {
                        message => "Must authorize first",
                        code    => "AuthorizationRequired"
                    }}}});
    return;
}

my $json_receiver = sub {
    my ($c, $p1) = @_;
    my $app = $c->app;
    my $log = $app->log;
    $log->debug("websocket got json " . $c->dumper($p1));

    my $source = $c->stash('source');

    if (my $token = $p1->{authorize}) {
        my ($client, $account, $email, $loginid) = BOM::WebSocketAPI::Authorize::authorize($c, $token);
        if (not $client) {
            return $c->send({
                    json => {
                        msg_type  => 'authorize',
                        echo_req  => $p1,
                        authorize => {
                            error => {
                                message => "Token invalid",
                                code    => "InvalidToken"
                            },
                        }}});
        } else {
            return $c->send({
                    json => {
                        msg_type  => 'authorize',
                        echo_req  => $p1,
                        authorize => {
                            fullname => $client->full_name,
                            loginid  => $client->loginid,
                            balance  => ($account ? $account->balance : 0),
                            currency => ($account ? $account->currency_code : ''),
                            email    => $email,
                        }}});
        }
    }

    if (my $id = $p1->{forget}) {
        BOM::WebSocketAPI::System::forget($c, $p1->{forget});
        return;
    }

    if ($p1->{payout_currencies}) {
        return $c->send({
                json => {
                    msg_type          => 'payout_currencies',
                    echo_req          => $p1,
                    payout_currencies => BOM::WebSocketAPI::ContractDiscovery::payout_currencies($c)}});
    }

    if (my $by = $p1->{active_symbols}) {
        return $c->send({
                json => {
                    msg_type       => 'active_symbols',
                    echo_req       => $p1,
                    active_symbols => BOM::WebSocketAPI::Symbols->active_symbols($by)}});
    }

    if (my $symbol = $p1->{contracts_for}) {
        return $c->send({
                json => {
                    msg_type      => 'contracts_for',
                    echo_req      => $p1,
                    contracts_for => BOM::Product::Contract::Finder::available_contracts_for_symbol($symbol)}});
    }

    if (my $options = $p1->{offerings}) {
        return $c->send({
                json => {
                    msg_type  => 'offerings',
                    echo_req  => $p1,
                    offerings => BOM::WebSocketAPI::Offerings::query($c, $options);
                }});
    }

    if ($p1->{portfolio}) {
        # TODO: Must go to BOM::WebSocketAPI::PortfolioManagement::portfolio($c);
        my $client = $c->stash('client') || return $c->_authorize_error($p1, 'portfolio');
        my $portfolio_stats = BOM::Product::Transaction::sell_expired_contracts({
                client => $client,
                source => $source
            }) || {number_of_sold_bets => 0};
        # TODO: run these under a separate event loop to avoid workload batching..
        my @fmbs = grep { !$c->{fmb_ids}->{$_->id} } $client->open_bets;
        $portfolio_stats->{batch_count} = @fmbs;
        my $count = 0;
        my $p0    = {%$p1};
        for my $fmb (@fmbs) {
            $p1->{fmb} = $fmb;
            my $p2 = $c->prepare_bid($p1);
            my $id;
            $id = Mojo::IOLoop->recurring(2 => sub { $c->send_bid($id, $p0, {}, $p2) });
            $c->{$id}                 = $p2;
            $c->{fmb_ids}->{$fmb->id} = $id;
            $p1->{batch_index}        = ++$count;
            $p1->{batch_count}        = @fmbs;
            $c->send_bid($id, $p0, $p1, $p2);
            $c->on(finish => sub { Mojo::IOLoop->remove($id); delete $c->{$id}; delete $c->{fmb_ids}{$fmb->id} });
        }
        return $c->send({
                json => {
                    msg_type        => 'portfolio_stats',
                    echo_req        => $p0,
                    portfolio_stats => $portfolio_stats
                }});
    }

    if (my $symbol = $p1->{ticks}) {
        # TODO: Must go to BOM::WebSocketAPI::MakretDiscovery::ticks($c);
        my $ul = BOM::Market::Underlying->new($symbol)
            || return $c->send({
                json => {
                    msg_type => 'tick',
                    echo_req => $p1,
                    tick     => {
                        error => {
                            message => "symbol $symbol invalid",
                            code    => "InvalidSymbol"
                        }}}});
        if ($p1->{end}) {
            my $style = delete($p1->{style}) || ($p1->{granularity} ? 'candles' : 'ticks');
            if ($style eq 'ticks') {
                my $ticks = $c->BOM::WebSocketAPI::Symbols::_ticks(%$p1, ul => $ul);
                my $history = {
                    prices => [map { $_->{price} } @$ticks],
                    times  => [map { $_->{time} } @$ticks],
                };
                return $c->send({
                        json => {
                            msg_type => 'history',
                            echo_req => $p1,
                            history  => $history
                        }});
            } elsif ($style eq 'candles') {
                my $candles = $c->BOM::WebSocketAPI::Symbols::_candles(%$p1, ul => $ul);
                return $c->send({
                        json => {
                            msg_type => 'candles',
                            echo_req => $p1,
                            candles  => $candles
                        }});
            } else {
                return $c->send({
                        json => {
                            msg_type => 'error',
                            echo_req => $p1,
                            error    => "style $style invalid"
                        }});
            }
        }
        if ($ul->feed_license eq 'realtime') {
            my $id;
            $id = Mojo::IOLoop->recurring(1 => sub { $c->send_tick($id, $p1, $ul) });
            $c->send_tick($id, $p1, $ul);
            $c->on(finish => sub { Mojo::IOLoop->remove($id); delete $c->{$id} });
        } else {
            return $c->send({
                    json => {
                        msg_type => 'tick',
                        echo_req => $p1,
                        tick     => {
                            error => {
                                message => "realtime quotes not available",
                                code    => "NoRealtimeQuotes"
                            }}}});
        }
    }

    if ($p1->{proposal}) {
        # TODO: Must go to BOM::WebSocketAPI::MakretDiscovery::proposal($c);

        # this is a recurring contract-price watch ("price streamer")
        # p2 is a manipulated copy of p1 suitable for produce_contract.
        my $p2 = $c->prepare_ask($p1);
        my $id;
        $id = Mojo::IOLoop->recurring(1 => sub { $c->send_ask($id, {}, $p2) });
        $c->{$id} = $p2;
        $c->send_ask($id, $p1, $p2);
        $c->on(finish => sub { Mojo::IOLoop->remove($id); delete $c->{$id} });
        return;
    }

    if (my $id = $p1->{buy}) {
        # TODO: Must go to BOM::WebSocketAPI::PortfolioManagement::buy($c);

        Mojo::IOLoop->remove($id);
        my $client = $c->stash('client') || return $c->_authorize_error($p1, 'open_receipt');
        my $json = {
            echo_req => $p1,
            msg_type => 'open_receipt'
        };
        {
            my $p2 = delete $c->{$id} || do {
                $json->{open_receipt}->{error}->{message} = "unknown contract proposal";
                $json->{open_receipt}->{error}->{code}    = "InvalidContractProposal";
                last;
            };
            my $contract = eval { produce_contract({%$p2}) } || do {
                my $err = $@;
                $log->debug("contract creation failure: $err");
                $json->{open_receipt}->{error}->{message} = "cannot create contract";
                $json->{open_receipt}->{error}->{code}    = "ContractCreationFailure";
                last;
            };
            my $trx = BOM::Product::Transaction->new({
                client   => $client,
                contract => $contract,
                price    => ($p1->{price} || 0),
                source   => $source,
            });
            if (my $err = $trx->buy) {
                $log->error("Contract-Buy Fail: " . $err->get_type . " $err->{-message_to_client}: $err->{-mesg}");
                $json->{open_receipt}->{error}->{message} = $err->{-message_to_client};
                $json->{open_receipt}->{error}->{code}    = $err->get_type;
                last;
            }
            $log->info("websocket-based buy " . $trx->report);
            $trx = $trx->transaction_record;
            my $fmb = $trx->financial_market_bet;
            $json->{open_receipt} = {
                trx_id        => $trx->id,
                fmb_id        => $fmb->id,
                balance_after => $trx->balance_after,
                purchase_time => $fmb->purchase_time->epoch,
                buy_price     => $fmb->buy_price,
                start_time    => $fmb->start_time->epoch,
                longcode      => $DOM->parse($contract->longcode)->all_text,
            };
        }
        return $c->send({json => $json});
    }

    if (my $id = $p1->{sell}) {
        # TODO: Must go to BOM::WebSocketAPI::PortfolioManagement::sell($c);

        Mojo::IOLoop->remove($id);
        my $client = $c->stash('client') || return $c->_authorize_error($p1, 'close_receipt');
        my $json = {
            echo_req => $p1,
            msg_type => 'close_receipt'
        };
        {
            my $p2 = delete $c->{$id} || do {
                $json->{error}                             = "";
                $json->{close_receipt}->{error}->{message} = "unknown contract sell proposal";
                $json->{close_receipt}->{error}->{code}    = "InvalidSellContractProposal";
                last;
            };
            my $fmb      = $p2->{fmb};
            my $contract = $p2->{contract};
            my $trx      = BOM::Product::Transaction->new({
                client      => $client,
                contract    => $contract,
                contract_id => $fmb->id,
                price       => ($p1->{price} || 0),
                source      => $source,
            });
            if (my $err = $trx->sell) {
                $log->error("Contract-Sell Fail: " . $err->get_type . " $err->{-message_to_client}: $err->{-mesg}");
                $json->{close_receipt}->{error}->{code}    = $err->get_type;
                $json->{close_receipt}->{error}->{message} = $err->{-message_to_client};
                last;
            }
            $log->info("websocket-based sell " . $trx->report);
            $trx                   = $trx->transaction_record;
            $fmb                   = $trx->financial_market_bet;
            $json->{close_receipt} = {
                trx_id        => $trx->id,
                fmb_id        => $fmb->id,
                balance_after => $trx->balance_after,
                sold_for      => abs($trx->amount),
            };
        }
        return $c->send({json => $json});
    }

    $log->error("unrecognised request");
    return;
};

sub entry_point {
    my $c   = shift;
    my $app = $c->app;
    my $log = $app->log;
    $log->debug("opening a websocket for " . $c->tx->remote_address);
    $c->inactivity_timeout(600);
    $c->on(json => $json_receiver);
    return;
}

1;

