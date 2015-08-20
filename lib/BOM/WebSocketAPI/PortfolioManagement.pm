package BOM::WebSocketAPI::PortfolioManagement;

use strict;
use warnings;

use Mojo::DOM;

use Try::Tiny;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Transaction;

sub buy {
    my ($c, $args) = @_;

    my $id = $args->{buy};
    my $source = $c->stash('source');

    Mojo::IOLoop->remove($id);
    my $client = $c->stash('client');
    my $json = {
        echo_req => $args,
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

1;

