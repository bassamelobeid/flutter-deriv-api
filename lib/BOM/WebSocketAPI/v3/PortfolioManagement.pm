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
use BOM::Platform::Context qw(localize request);

sub buy {
    my ($c, $args) = @_;

    BOM::Platform::Context::request($c->stash('request'));

    my $purchase_date = time;                  # Purchase is considered to have happened at the point of request.
    my $id            = $args->{buy};
    my $source        = $c->stash('source');
    my $ws_id         = $c->tx->connection;

    my $client = $c->stash('client');
    my $p2 = BOM::WebSocketAPI::v3::System::forget_one $c, $id
        or return $c->new_error('buy', 'InvalidContractProposal', localize("Unknown contract proposal"));
    $p2 = $p2->{data};

    my $contract = try { produce_contract({%$p2}) } || do {
        my $err = $@;
        $c->app->log->debug("contract creation failure: $err");
        return $c->new_error('buy', 'ContractCreationFailure', localize('Cannot create contract'));
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
        return $c->new_error('buy', $err->get_type, $err->{-message_to_client});
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

    return {
        msg_type => 'buy',
        buy      => $response
    };
}

sub sell {
    my ($c, $args) = @_;

    BOM::Platform::Context::request($c->stash('request'));

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

    my $fmb = $fmb_dm->get_fmb_by_id([$id]);
    return $c->new_error('sell', 'InvalidSellContractProposal', localize('Unknown contract sell proposal')) unless $fmb;

    my $contract = produce_contract(${$fmb}[0]->short_code, $client->currency);
    my $trx = BOM::Product::Transaction->new({
        client      => $client,
        contract    => $contract,
        contract_id => $id,
        price       => ($args->{price} || 0),
        source      => $source,
    });

    if (my $err = $trx->sell) {
        $c->app->log->error("Contract-Sell Fail: " . $err->get_type . " $err->{-message_to_client}: $err->{-mesg}");
        return $c->new_error('sell', $err->get_type, $err->{-message_to_client});
    }

    $trx = $trx->transaction_record;

    return {
        msg_type => 'sell',
        sell     => {
            transaction_id => $trx->id,
            contract_id    => $id,
            balance_after  => $trx->balance_after,
            sold_for       => abs($trx->amount),
        }};

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
            my $fmb_map = ($c->{fmb_ids}{$ws_id} //= {});
            $fmb_map->{$fmb->id} = $id;

            my $data = {
                id      => $id,
                type    => 'proposal_open_contract',
                data    => {%$p2},
                cleanup => sub {
                    Mojo::IOLoop->remove($id);
                    delete $fmb_map->{$fmb->id};
                    # TODO: we might want to send an error to the client
                    # if this function is called with a parameter indicating
                    # the proposal stream was closed due to an error.
                },
            };
            BOM::WebSocketAPI::v3::System::limit_stream_count($c, $data);
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

    BOM::Platform::Context::request($c->stash('request'));

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
                message => localize("Cannot create sell contract"),
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

    my %returnhash = (
        ask_price           => sprintf('%.2f', $contract->ask_price),
        bid_price           => sprintf('%.2f', $contract->bid_price),
        current_spot_time   => $contract->current_tick->epoch,
        contract_id         => $p2->{contract_id},
        underlying          => $contract->underlying->symbol,
        is_expired          => $contract->is_expired,
        is_valid_to_sell    => $contract->is_valid_to_sell,
        is_forward_starting => $contract->is_forward_starting,
        is_path_dependent   => $contract->is_path_dependent,
        is_intraday         => $contract->is_intraday,
        date_start          => $contract->date_start->epoch,
        date_expiry         => $contract->date_expiry->epoch,
        date_settlement     => $contract->date_settlement->epoch,
        currency            => $contract->currency,
        longcode            => $contract->longcode,
        shortcode           => $contract->shortcode,
        payout              => $contract->payout,
    );

    if ($contract->expiry_type eq 'tick') {
        $returnhash{prediction}      = $contract->long_term_prediction;
        $returnhash{tick_count}      = $contract->average_tick_count;
        $returnhash{entry_tick}      = $contract->entry_tick->quote;
        $returnhash{entry_tick_time} = $contract->entry_tick->quote;
        $returnhash{exit_tick}       = $contract->exit_tick->quote;
        $returnhash{exit_tick_time}  = $contract->exit_tick->epoch;
    } else {
        $returnhash{current_spot} = $contract->current_spot;
    }

    if ($contract->two_barriers) {
        $returnhash{high_barrier} = $contract->high_barrier->as_absolute;
        $returnhash{low_barrier}  = $contract->low_barrier->as_absolute;
    } elsif ($contract->barrier) {
        $returnhash{barrier} = $contract->barrier->as_absolute;
    }

    if ($contract->expiry_type ne 'tick' and not $contract->is_valid_to_sell) {
        $returnhash{validation_error} = $contract->primary_validation_error->message_to_client;
    }

    return \%returnhash;
}

sub send_bid {
    my ($c, $id, $p0, $p2) = @_;

    BOM::Platform::Context::request($c->stash('request'));

    my $latest = get_bid($c, $p2);

    my $response = {
        msg_type => 'proposal_open_contract',
        echo_req => $p0,
    };

    if ($latest->{error}) {
        BOM::WebSocketAPI::v3::System::forget_one $c, $id;
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
