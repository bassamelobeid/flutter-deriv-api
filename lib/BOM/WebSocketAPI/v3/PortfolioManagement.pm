package BOM::WebSocketAPI::v3::PortfolioManagement;

use strict;
use warnings;

use Mojo::DOM;
use Date::Utility;
use Try::Tiny;

use BOM::WebSocketAPI::v3::Utility;
use BOM::WebSocketAPI::v3::System;
use BOM::WebSocketAPI::v3::MarketDiscovery;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw (localize);
use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);
use BOM::Product::Transaction;

sub buy {
    my ($c, $args) = @_;

    my $purchase_date = time;                  # Purchase is considered to have happened at the point of request.
    my $id            = $args->{buy};
    my $source        = $c->stash('source');

    my $client = $c->stash('client');
    my $p2 = BOM::WebSocketAPI::v3::System::forget_one $c, $id
        or return $c->new_error('buy', 'InvalidContractProposal', $c->l("Unknown contract proposal"));
    $p2 = BOM::WebSocketAPI::v3::MarketDiscovery::prepare_ask($p2);

    my $contract = try { produce_contract({%$p2}) } || do {
        my $err = $@;
        $c->app->log->debug("contract creation failure: $err");
        return $c->new_error('buy', 'ContractCreationFailure', $c->l('Cannot create contract'));
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
    my ($client, $source, $args) = @_;

    my $id = $args->{sell};

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
    return BOM::WebSocketAPI::v3::Utility::create_error({
            code              => 'InvalidSellContractProposal',
            message_to_client => BOM::Platform::Context::localize('Unknown contract sell proposal')}) unless $fmb;

    my $contract = produce_contract(${$fmb}[0]->short_code, $client->currency);
    my $trx = BOM::Product::Transaction->new({
        client      => $client,
        contract    => $contract,
        contract_id => $id,
        price       => ($args->{price} || 0),
        source      => $source,
    });

    if (my $err = $trx->sell) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
            code              => $err->get_type,
            message_to_client => $err->{-message_to_client},
            message           => "Contract-Sell Fail: " . $err->get_type . " $err->{-message_to_client}: $err->{-mesg}"
        });
    }

    $trx = $trx->transaction_record;

    return {
        transaction_id => $trx->id,
        contract_id    => $id,
        balance_after  => $trx->balance_after,
        sold_for       => abs($trx->amount),
    };

}

sub proposal_open_contract {    ## no critic (Subroutines::RequireFinalReturn)
    my ($c, $args) = @_;

    my $client = $c->stash('client');
    my $source = $c->stash('source');

    my @fmbs = ();
    if ($args->{contract_id}) {
        @fmbs = grep { $args->{contract_id} eq $_->id } $client->open_bets;
    } else {
        @fmbs = $client->open_bets;
    }

    if (scalar @fmbs > 0) {
        foreach my $fmb (@fmbs) {
            my $details = {%$args};
            $details->{short_code} = $fmb->short_code;
            $details->{fmb_id}     = $fmb->id;
            $details->{currency}   = $client->currency;

            my $id = BOM::WebSocketAPI::v3::MarketDiscovery::_feed_channel($c, 'subscribe', $fmb->underlying_symbol,
                'proposal_open_contract:' . JSON::to_json($args));
            send_bid($c, $id, $args, $details);
        }
    } else {
        return {
            echo_req               => $args,
            msg_type               => 'proposal_open_contract',
            proposal_open_contract => {}};
    }
}

sub portfolio {
    my $client = shift;

    my $portfolio = {contracts => []};
    foreach my $row (@{__get_open_contracts($client)}) {
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

    return $portfolio,;
}

sub __get_open_contracts {
    my $client = shift;

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

sub get_bid {
    my ($short_code, $fmb_id, $currency) = @_;

    my $contract = produce_contract($short_code, $currency);

    my %returnhash = (
        ask_price           => sprintf('%.2f', $contract->ask_price),
        bid_price           => sprintf('%.2f', $contract->bid_price),
        current_spot_time   => $contract->current_tick->epoch,
        contract_id         => $fmb_id,
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
        $returnhash{entry_spot}   = $contract->entry_spot;
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
    my ($c, $id, $args, $details) = @_;

    my $latest = get_bid($details->{short_code}, $details->{fmb_id}, $details->{currency});

    my $response = {
        msg_type => 'proposal_open_contract',
        echo_req => $args,
    };

    $c->send({
            json => {
                %$response,
                proposal_open_contract => {
                    id => $id,
                    %$latest
                }}});

    return;
}

1;
