package BOM::WebSocketAPI::PortfolioManagement;

use strict;
use warnings;

use Mojo::DOM;

use Try::Tiny;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Transaction;

sub buy {
    my ($c, $args) = @_;

    my $id     = $args->{buy};
    my $source = $c->stash('source');

    Mojo::IOLoop->remove($id);
    my $client = $c->stash('client');
    my $json   = {
        msg_type => 'open_receipt'
    };
    {
        my $p2 = delete $c->{$id} || do {
            $json->{open_receipt}->{error}->{message} = "unknown contract proposal";
            $json->{open_receipt}->{error}->{code}    = "InvalidContractProposal";
            last;
        };
        my $contract = try { produce_contract({%$p2}) } || do {
            my $err = $@;
            $c->app->log->debug("contract creation failure: $err");
            $json->{open_receipt}->{error}->{message} = "cannot create contract";
            $json->{open_receipt}->{error}->{code}    = "ContractCreationFailure";
            last;
        };
        my $trx = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
            price    => ($args->{price} || 0),
            source   => $source,
        });
        if (my $err = $trx->buy) {
            $c->app->log->error("Contract-Buy Fail: " . $err->get_type . " $err->{-message_to_client}: $err->{-mesg}");
            $json->{open_receipt}->{error}->{message} = $err->{-message_to_client};
            $json->{open_receipt}->{error}->{code}    = $err->get_type;
            last;
        }
        $c->app->log->info("websocket-based buy " . $trx->report);
        $trx = $trx->transaction_record;
        my $fmb = $trx->financial_market_bet;
        $json->{open_receipt} = {
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

    Mojo::IOLoop->remove($id);
    my $client = $c->stash('client');
    my $json   = {
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
            price       => ($args->{price} || 0),
            source      => $source,
        });
        if (my $err = $trx->sell) {
            $c->app->log->error("Contract-Sell Fail: " . $err->get_type . " $err->{-message_to_client}: $err->{-mesg}");
            $json->{close_receipt}->{error}->{code}    = $err->get_type;
            $json->{close_receipt}->{error}->{message} = $err->{-message_to_client};
            last;
        }
        $c->app->log->info("websocket-based sell " . $trx->report);
        $trx                   = $trx->transaction_record;
        $fmb                   = $trx->financial_market_bet;
        $json->{close_receipt} = {
            trx_id        => $trx->id,
            fmb_id        => $fmb->id,
            balance_after => $trx->balance_after,
            sold_for      => abs($trx->amount),
        };
    }

    return $json;
}

sub portfolio {
    my ($c, $args) = @_;

    my $client = $c->stash('client');
    my $source = $c->stash('source');

    my $portfolio_stats = BOM::Product::Transaction::sell_expired_contracts({
            client => $client,
            source => $source
        }) || {number_of_sold_bets => 0};

    # TODO: run these under a separate event loop to avoid workload batching..
    my @fmbs = grep { !$c->{fmb_ids}->{$_->id} } $client->open_bets;
    $portfolio_stats->{batch_count} = @fmbs;
    my $count = 0;
    my $p0    = {%$args};
    for my $fmb (@fmbs) {
        $args->{fmb} = $fmb;
        my $p2 = $c->prepare_bid($args);
        my $id;
        $id = Mojo::IOLoop->recurring(2 => sub { $c->send_bid($id, $p0, {}, $p2) });
        $c->{$id}                 = $p2;
        $c->{fmb_ids}->{$fmb->id} = $id;
        $args->{batch_index}      = ++$count;
        $args->{batch_count}      = @fmbs;
        $c->send_bid($id, $p0, $args, $p2);
        $c->on(finish => sub { Mojo::IOLoop->remove($id); delete $c->{$id}; delete $c->{fmb_ids}{$fmb->id} });
    }

    return $portfolio_stats;
}

1;

