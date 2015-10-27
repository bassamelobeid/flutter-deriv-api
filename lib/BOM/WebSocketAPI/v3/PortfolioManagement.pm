package BOM::WebSocketAPI::v3::PortfolioManagement;

use strict;
use warnings;

use Mojo::DOM;
use Date::Utility;
use Try::Tiny;

use BOM::WebSocketAPI::v3::System;
use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);
use BOM::Product::Transaction;
use BOM::Platform::Runtime;

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
        my $response = {
            transaction_id => $trx->transaction_id,
            contract_id    => $trx->contract_id,
            balance_after  => $trx->balance_after,
            purchase_time  => $trx->purchase_date->epoch,
            buy_price      => $trx->price,
            start_time     => $contract->date_start->epoch,
            longcode       => Mojo::DOM->new->parse($contract->longcode)->all_text,
            shortcode      => $contract->shortcode,
        };

        if ($contract->is_spread) {
            $response->{stop_loss_level}   = $contract->stop_loss_level;
            $response->{stop_profit_level} = $contract->stop_profit_level;
            $response->{amount_per_point}  = $contract->amount_per_point;
        }

        $json->{buy} = $response;
    }

    return $json;
}

sub sell {
    my ($c, $args) = @_;

    my $id     = $args->{sell};
    my $source = $c->stash('source');
    my $client = $c->stash('client');

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
            client_loginid => $client->loginid,
            currency_code  => $client->currency,
            db             => BOM::Database::ClientDB->new({
                    client_loginid => $client->loginid,
                    operation      => 'replica',
                }
            )->db,
        });

    my $json = {msg_type => 'sell'};

    my $fmb = $dm->get_fmb_by_id($id)->[0];
    if ($fmb) {
        my $contract = produce_contract($fmb->short_code, $client->currency);
        my $trx = BOM::Product::Transaction->new({
            client      => $client,
            contract    => $contract,
            contract_id => $id,
            price       => ($args->{price} || 0),
            source      => $source,
        });

        if (my $err = $trx->sell) {
            $c->app->log->error("Contract-Sell Fail: " . $err->get_type . " $err->{-message_to_client}: $err->{-mesg}");
            $json->{error}->{code}    = $err->get_type;
            $json->{error}->{message} = $err->{-message_to_client};
        } else {
            $trx = $trx->transaction_record;
            $json->{sell} = {
                transaction_id => $trx->id,
                contract_id    => $id,
                balance_after  => $trx->balance_after,
                sold_for       => abs($trx->amount),
            };
        }
    } else {
        $json->{error}            = "";
        $json->{error}->{message} = "unknown contract sell proposal";
        $json->{error}->{code}    = "InvalidSellContractProposal";
    }

    return $json;
}

sub proposal_open_contract {    ## no critic (Subroutines::RequireFinalReturn)
    my ($c, $args) = @_;

    my $client = $c->stash('client');
    my $source = $c->stash('source');
    my $ws_id  = $c->tx->connection;

    my @fmbs = ();
    if ($args->{contract_id}) {
        @fmbs = grep { $args->{contract_id} eq $_->id } $client->open_bets;
    } else {
        @fmbs = $client->open_bets;
    }

    my $p0 = {%$args};
    if (scalar @fmbs > 0) {
        foreach my $fmb (@fmbs) {
            my $id = '';
            $args->{fmb} = $fmb;
            my $p2 = prepare_bid($c, $args);
            $p2->{contract_id} = $fmb->id;
            $id = Mojo::IOLoop->recurring(2 => sub { send_bid($c, $id, $p0, $p2) });

            $c->{ws}{$ws_id}{$id} = {
                started => time(),
                type    => 'proposal_open_contract',
                data    => {%$p2},
            };
            BOM::WebSocketAPI::v3::System::_limit_stream_count($c);

            $c->{fmb_ids}{$ws_id}{$fmb->id} = $id;
        }
    } else {
        return {
            echo_req               => $args,
            msg_type               => 'proposal_open_contract',
            proposal_open_contract => {}};
    }
}

sub portfolio {
    my ($c, $args) = @_;

    my $client = $c->stash('client');
    my $portfolio = {contracts => []};

    foreach my $row (@{__get_open_contracts($c)}) {
        my %trx = (
            contract_id    => $row->{id},
            transaction_id => $row->{buy_id},
            purchase_time  => Date::Utility->new($row->{purchase_time})->epoch,
            symbol         => $row->{underlying_symbol},
            payout         => $row->{payout_price},
            buy_price      => $row->{buy_price},
            date_start     => Date::Utility->new($row->{start_time})->epoch,
            expiry_time    => Date::Utility->new($row->{expiry_time})->epoch,
            contract_type  => $row->{bet_type},
            currency       => $client->currency,
            shortcode      => $row->{short_code},
            longcode =>
                Mojo::DOM->new->parse(BOM::Product::ContractFactory::produce_contract($row->{short_code}, $client->currency)->longcode)->all_text
        );
        push $portfolio->{contracts}, \%trx;
    }

    return {
        msg_type  => 'portfolio',
        portfolio => $portfolio,
    };
}

sub __get_open_contracts {
    my $c = shift;

    my $client = $c->stash('client');

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
            client_loginid => $client->loginid,
            currency_code  => $client->currency,
            db             => BOM::Database::ClientDB->new({
                    client_loginid => $client->loginid,
                    operation      => 'replica',
                }
            )->db,
        });

    return $fmb_dm->get_open_bets_of_account();
}

sub prepare_bid {
    my ($c, $p1) = @_;
    my $app      = $c->app;
    my $log      = $app->log;
    my $fmb      = delete $p1->{fmb};
    my $currency = $fmb->account->currency_code;
    my $contract = produce_contract($fmb->short_code, $currency);
    %$p1 = (
        contract_id   => $fmb->id,
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
        ask_price   => sprintf('%.2f', $contract->ask_price),
        bid_price   => sprintf('%.2f', $contract->bid_price),
        spot        => $contract->current_spot,
        spot_time   => $contract->current_tick->epoch,
        contract_id => $p2->{contract_id}};
}

sub send_bid {
    my ($c, $id, $p0, $p2) = @_;
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
                    },
                    %$latest,
                }});
    } else {
        $c->send({
                json => {
                    %$response,
                    proposal_open_contract => {
                        id => $id,
                        %$latest
                    }}});
    }
    return;
}

1;
