package BOM::RPC::v3::Transaction;

use strict;
use warnings;

use Try::Tiny;

use BOM::RPC::v3::Contract;
use BOM::RPC::v3::Utility;
use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);
use BOM::Product::Transaction;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Client;

sub buy {
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    my $client              = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    my $source              = $params->{source};
    my $contract_parameters = $params->{contract_parameters};
    my $args                = $params->{args};

    my $purchase_date = time;    # Purchase is considered to have happened at the point of request.
    $contract_parameters = BOM::RPC::v3::Contract::prepare_ask($contract_parameters);

    my $contract = try { produce_contract({%$contract_parameters}) } || do {
        my $err = $@;
        return BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize('Cannot create contract')});
    };

    my $trx = BOM::Product::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => ($args->{price} || 0),
        purchase_date => $purchase_date,
        source        => $source,
    });

    if (my $err = $trx->buy) {
        return BOM::RPC::v3::Utility::create_error({
            code              => $err->get_type,
            message_to_client => $err->{-message_to_client},
        });
    }

    my $response = {
        transaction_id => $trx->transaction_id,
        contract_id    => $trx->contract_id,
        balance_after  => $trx->balance_after,
        purchase_time  => $trx->purchase_date->epoch,
        buy_price      => $trx->price,
        start_time     => $contract->date_start->epoch,
        longcode       => $contract->longcode,
        shortcode      => $contract->shortcode,
        payout         => $contract->payout
    };

    if ($contract->is_spread) {
        $response->{stop_loss_level}   = $contract->stop_loss_level;
        $response->{stop_profit_level} = $contract->stop_profit_level;
        $response->{amount_per_point}  = $contract->amount_per_point;
    }

    return $response;
}

sub sell {
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    my $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    my $source = $params->{source};
    my $args   = $params->{args};
    my $id     = $args->{sell};

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
    return BOM::RPC::v3::Utility::create_error({
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
        return BOM::RPC::v3::Utility::create_error({
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

1;
