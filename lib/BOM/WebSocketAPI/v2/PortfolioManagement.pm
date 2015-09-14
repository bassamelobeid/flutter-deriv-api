package BOM::WebSocketAPI::v2::PortfolioManagement;

use strict;
use warnings;

use Mojo::DOM;
use BOM::WebSocketAPI::v2::System;

use Try::Tiny;
use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);
use BOM::Product::Transaction;

sub buy {
    my ($c, $args) = @_;

    my $purchase_date = time;                  # Purchase is considered to have happened at the point of request.
    my $id            = $args->{buy};
    my $source        = $c->stash('source');
    my $ws_id         = $c->tx->connection;

    Mojo::IOLoop->remove($id);
    my $client = $c->stash('client');
    my $json = {msg_type => 'buy'};
    {
        my $p2 = delete $c->{ws}{$ws_id}{$id}{data} || do {
            $json->{error}->{message} = "unknown contract proposal";
            $json->{error}->{code}    = "InvalidContractProposal";
            last;
        };
        my $contract = try { produce_contract({%$p2}) } || do {
            my $err = $@;
            $c->app->log->debug("contract creation failure: $err");
            $json->{error}->{message} = "cannot create contract";
            $json->{error}->{code}    = "ContractCreationFailure";
            last;
        };
        my $trx = BOM::Product::Transaction->new({
            client        => $client,
            contract      => $contract,
            price         => ($args->{price} || 0),
            purchase_date => $purchase_date,
            source        => $source,
        });
        if (my $err = $trx->buy) {
            $c->app->log->error("Contract-Buy Fail: " . $err->get_type . " $err->{-message_to_client}: $err->{-mesg}");
            $json->{error}->{message} = $err->{-message_to_client};
            $json->{error}->{code}    = $err->get_type;
            last;
        }
        $trx = $trx->transaction_record;
        my $fmb = $trx->financial_market_bet;
        $json->{buy} = {
            trx_id        => $trx->id,
            fmb_id        => $fmb->id,
            balance_after => $trx->balance_after,
            purchase_time => $fmb->purchase_time->epoch,
            buy_price     => $fmb->buy_price,
            start_time    => $fmb->start_time->epoch,
            longcode      => Mojo::DOM->new->parse($contract->longcode)->all_text,
        };
    }

    return $json;
}

sub sell {
    my ($c, $args) = @_;

    my $id     = $args->{sell};
    my $source = $c->stash('source');
    my $ws_id  = $c->tx->connection;

    Mojo::IOLoop->remove($id);
    my $client = $c->stash('client');
    my $json = {msg_type => 'sell'};
    {
        my $p2 = delete $c->{ws}{$ws_id}{$id}{data} || do {
            $json->{error}            = "";
            $json->{error}->{message} = "unknown contract sell proposal";
            $json->{error}->{code}    = "InvalidSellContractProposal";
            last;
        };
        my $fmb      = $p2->{fmb};
        my $contract = $p2->{contract};
        my $trx      = BOM::Product::Transaction->new({
            client      => $client,
            contract    => $contract,
            contract_id => $fmb->id,
            price       => ($args->{price} || 0),
            source      => $source,
        });
        if (my $err = $trx->sell) {
            $c->app->log->error("Contract-Sell Fail: " . $err->get_type . " $err->{-message_to_client}: $err->{-mesg}");
            $json->{error}->{code}    = $err->get_type;
            $json->{error}->{message} = $err->{-message_to_client};
            last;
        }
        $trx          = $trx->transaction_record;
        $fmb          = $trx->financial_market_bet;
        $json->{sell} = {
            trx_id        => $trx->id,
            fmb_id        => $fmb->id,
            balance_after => $trx->balance_after,
            sold_for      => abs($trx->amount),
        };
    }

    return $json;
}

sub proposal_open_contract {    ## no critic (Subroutines::RequireFinalReturn)
    my ($c, $args) = @_;

    my $client = $c->stash('client');
    my $source = $c->stash('source');
    my $ws_id  = $c->tx->connection;

    my @fmbs = grep { $args->{fmb_id} eq $_->id } $client->open_bets;
    my $p0 = {%$args};
    if (scalar @fmbs > 0) {
        my $fmb = $fmbs[0];
        my $id  = '';
        $args->{fmb} = $fmb;
        my $p2 = prepare_bid($c, $args);
        $id = Mojo::IOLoop->recurring(2 => sub { send_bid($c, $id, $p0, {}, $p2) });

        $c->{ws}{$ws_id}{$id} = {
            started => time(),
            type    => 'proposal_open_contract',
            data    => {%$p2},
        };
        BOM::WebSocketAPI::v2::System::_limit_stream_count($c);

        $c->{fmb_ids}{$ws_id}{$fmb->id} = $id;
        send_bid($c, $id, $p0, $args, $p2);
    } else {
        return {
            echo_req => $args,
            msg_type => 'proposal_open_contract',
            error    => {
                message => "Not found",
                code    => "NotFound"
            }};
    }
}

sub portfolio {
    my ($c, $args) = @_;

    my $client = $c->stash('client');
    my $source = $c->stash('source');
    my $ws_id  = $c->tx->connection;

    BOM::Product::Transaction::sell_expired_contracts({
        client => $client,
        source => $source
    });

    # TODO: run these under a separate event loop to avoid workload batching..
    my @fmbs = grep { !$c->{fmb_ids}{$ws_id}{$_->id} } $client->open_bets;
    my $portfolio;
    $portfolio->{contracts} = [];
    my $count = 0;
    my $p0    = {%$args};
    for my $fmb (@fmbs) {
        my $id = '';

        if (($args->{spawn} // '') eq '1') {
            $args->{fmb} = $fmb;
            my $p2 = prepare_bid($c, $args);
            $id = Mojo::IOLoop->recurring(2 => sub { send_bid($c, $id, $p0, {}, $p2) });

            $c->{ws}{$ws_id}{$id} = {
                started => time(),
                type    => 'portfolio',
                data    => {%$p2}};
            BOM::WebSocketAPI::v2::System::_limit_stream_count($c);

            $c->{fmb_ids}{$ws_id}{$fmb->id} = $id;
            send_bid($c, $id, $p0, $args, $p2);
        }

        push @{$portfolio->{contracts}},
            {
            fmb_id        => $fmb->id,
            purchase_time => $fmb->purchase_time->epoch,
            symbol        => $fmb->underlying_symbol,
            payout        => $fmb->payout_price,
            buy_price     => $fmb->buy_price,
            date_start    => $fmb->start_time->epoch,
            expiry_time   => $fmb->expiry_time->epoch,
            contract_type => $fmb->bet_type,
            currency      => $fmb->account->currency_code,
            longcode      => Mojo::DOM->new->parse(produce_contract($fmb->short_code, $fmb->account->currency_code)->longcode)->all_text,
            };
    }

    return {
        msg_type  => 'portfolio',
        portfolio => $portfolio,
    };
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
        longcode      => Mojo::DOM->new->parse($contract->longcode)->all_text,
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
    my $contract = try { make_similar_contract(@similar_args) } || do {
        my $err = $@;
        $log->info("contract for sale creation failure: $err");
        return {
            error => {
                message => "cannot create sell contract",
                code    => "ContractSellCreateError"
            }};
    };
    if (!$contract->is_valid_to_sell) {
        $log->error("primary error: " . $contract->primary_validation_error->message);
        return {
            error => {
                message => $contract->primary_validation_error->message_to_client,
                code    => "ContractSellValidationError"
            }};
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
    my $latest = get_bid($c, $p2);

    my $response = {
        msg_type => 'proposal_open_contract',
        echo_req => $p0,
    };

    if ($latest->{error}) {
        Mojo::IOLoop->remove($id);
        my $ws_id = $c->tx->connection;
        delete $c->{ws}{$ws_id}{$id};
        delete $c->{fmb_ids}{$ws_id}{$p2->{fmb}->id};
        $c->send({
                json => {
                    %$response,
                    proposal_open_contract => {
                        id => $id,
                        %$p1,
                    },
                    %$latest,
                }});
    } else {
        $c->send({
                json => {
                    %$response,
                    proposal_open_contract => {
                        id => $id,
                        %$p1,
                        %$latest
                    }}});
    }
    return;
}

1;
