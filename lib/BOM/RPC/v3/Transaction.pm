package BOM::RPC::v3::Transaction;

use strict;
use warnings;

use Try::Tiny;

use BOM::RPC::v3::Contract;
use BOM::RPC::v3::Utility;
use BOM::RPC::v3::PortfolioManagement;
use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);
use BOM::Product::Transaction;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Client;
use BOM::Database::DataMapper::FinancialMarketBet;

sub buy {
    my $params = shift;

    my $token_details = $params->{token_details};
    return BOM::RPC::v3::Utility::invalid_token_error() unless ($token_details and exists $token_details->{loginid});

    my $client = BOM::Platform::Client->new({loginid => $token_details->{loginid}});

    # NOTE: no need to call BOM::RPC::v3::Utility::check_authorization. All checks
    #       are done again in BOM::Product::Transaction
    return BOM::RPC::v3::Utility::create_error({
            code              => 'AuthorizationRequired',
            message_to_client => localize('Please log in.')}) unless $client;

    my $source              = $params->{source};
    my $contract_parameters = $params->{contract_parameters};
    my $args                = $params->{args};

    my $purchase_date = time;    # Purchase is considered to have happened at the point of request.
    $contract_parameters = BOM::RPC::v3::Contract::prepare_ask($contract_parameters);

    my $contract = try { produce_contract($contract_parameters) }
        || return BOM::RPC::v3::Utility::create_error({
            code              => 'ContractCreationFailure',
            message_to_client => BOM::Platform::Context::localize('Cannot create contract')});

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

my %_allowed_result_members_on_success;
@_allowed_result_members_on_success{
    qw/
        token transaction_id contract_id purchase_time buy_price
        start_time longcode shortcode paypout stop_loss_level
        stop_profit_level amount_per_point/
} = ();

my %_allowed_result_members_on_error;
@_allowed_result_members_on_error{qw/token code error/} = ();

sub buy_contract_for_multiple_accounts {
    my $params = shift;

    my $token_details = $params->{token_details};
    Test::More::note Test::More::explain $token_details;
    return BOM::RPC::v3::Utility::invalid_token_error() unless ($token_details and exists $token_details->{loginid});

    my $client = BOM::Platform::Client->new({loginid => $token_details->{loginid}});

    # NOTE: no need to call BOM::RPC::v3::Utility::check_authorization. All checks
    #       are done again in BOM::Product::Transaction
    return BOM::RPC::v3::Utility::create_error({
            code              => 'AuthorizationRequired',
            message_to_client => localize('Please log in.')}) unless $client;

    my @result;
    my $found_at_least_one;

    my $msg = BOM::Platform::Context::localize('Invalid token');
    for my $t (@{$params->{tokens} || []}) {
        my $token_details = BOM::RPC::v3::Utility::get_token_details($t);
        my $loginid;
        unless ($token_details and $loginid = $token_details->{loginid}) {
            push @result,
                +{
                token => $t,
                code  => 'InvalidToken',
                error => $msg,
                };
            next;
        }

        push @result,
            +{
            token   => $t,
            loginid => $loginid,
            };
        $found_at_least_one = 1;
    }

    return \@result unless $found_at_least_one;

    # NOTE: we rely here on BOM::Product::Transaction to perform all the
    #       client validations like client_status and self_exclusion.

    my $source              = $params->{source};
    my $contract_parameters = $params->{contract_parameters};
    my $args                = $params->{args};

    my $purchase_date = time;    # Purchase is considered to have happened at the point of request.
    $contract_parameters = BOM::RPC::v3::Contract::prepare_ask($contract_parameters);

    my $contract = try { produce_contract({%$contract_parameters}) }
        || return BOM::RPC::v3::Utility::create_error({
            code              => 'ContractCreationFailure',
            message_to_client => localize('Cannot create contract')});

    my $trx = BOM::Product::Transaction->new({
        client        => $client,
        multiple      => \@result,
        contract      => $contract,
        price         => ($args->{price} || 0),
        purchase_date => $purchase_date,
        source        => $source,
    });

    if (my $err = $trx->batch_buy) {
        return BOM::RPC::v3::Utility::create_error({
            code              => $err->get_type,
            message_to_client => $err->{-message_to_client},
        });
    }

    for my $el (@result) {
        if (exists $el->{code}) {
            delete @{$el}{grep { !exists $_allowed_result_members_on_error{$_} } keys %$el};
        } else {
            delete @{$el}{grep { !exists $_allowed_result_members_on_success{$_} } keys %$el};
        }
    }

    return \@result;
}

sub sell {
    my $params = shift;

    my $client = $params->{client};

    my ($source, $args) = ($params->{source}, $params->{args});
    my $id = $args->{sell};

    my @fmbs = @{__get_contract_by_id($client, $id)};
    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidSellContractProposal',
            message_to_client => BOM::Platform::Context::localize('Unknown contract sell proposal')}) unless @fmbs;

    my $contract = produce_contract($fmbs[0]->{short_code}, $client->currency);
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

sub __get_contract_by_id {
    my $client      = shift;
    my $contract_id = shift;

    my $mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        broker_code => $client->broker_code,
        operation   => 'replica'
    });
    return $mapper->get_contract_by_id($contract_id);
}

1;
