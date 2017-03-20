package BOM::RPC::v3::Transaction;

use strict;
use warnings;

use Try::Tiny;
use JSON::XS qw/encode_json/;
use BOM::RPC::v3::Contract;
use BOM::RPC::v3::Utility;
use BOM::RPC::v3::PortfolioManagement;
use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);
use BOM::Product::ContractFactory::Parser qw( shortcode_to_parameters );
use BOM::Transaction;
use BOM::Platform::Context qw (localize request);
use Client::Account;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;

sub buy {
    my $params = shift;

    my $client               = $params->{client} // die "client should be authed when get here";
    my $source               = $params->{source};
    my $contract_parameters  = $params->{contract_parameters};
    my $args                 = $params->{args};
    my $payout               = $params->{payout};
    my $trading_period_start = $contract_parameters->{trading_period_start};
    my $purchase_date = time;    # Purchase is considered to have happened at the point of request.
    $contract_parameters = BOM::RPC::v3::Contract::prepare_ask($contract_parameters);
    $contract_parameters->{landing_company} = $client->landing_company->short;
    my $amount_type = $contract_parameters->{amount_type};
    my ($contract, $response);

    try {
        die
            unless BOM::RPC::v3::Contract::pre_validate_start_expire_dates($contract_parameters);
    }
    catch {
        warn __PACKAGE__ . " buy pre_validate_start_expire_dates failed, parameters: " . encode_json($contract_parameters);
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize('Cannot create contract')});
    };
    return $response if $response;
    try {
        $contract = produce_contract($contract_parameters);
    }
    catch {
        warn __PACKAGE__ . " buy produce_contract failed, parameters: " . encode_json($contract_parameters);
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize('Cannot create contract')});
    };
    return $response if $response;

    my $price = $args->{price};
    if (defined $amount_type and $amount_type eq 'stake') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize("Contract's stake amount is more than the maximum purchase price.")}
        ) if ($price < $contract_parameters->{amount});
        $price = $contract_parameters->{amount};
    }

    my $trx = BOM::Transaction->new({
            client   => $client,
            contract => $contract,
            price    => ($price || 0),
            (defined $payout)      ? (payout      => $payout)      : (),
            (defined $amount_type) ? (amount_type => $amount_type) : (),
            purchase_date => $purchase_date,
            source        => $source,
            (defined $trading_period_start)
            ? (trading_period_start => $trading_period_start)
            : (),
        });

    if (my $err = $trx->buy) {
        return BOM::RPC::v3::Utility::create_error({
            code              => $err->get_type,
            message_to_client => $err->{-message_to_client},
        });
    }

    $response = {
        transaction_id => $trx->transaction_id,
        contract_id    => $trx->contract_id,
        balance_after  => sprintf('%.2f', $trx->balance_after),
        purchase_time  => $trx->purchase_date->epoch,
        buy_price      => $trx->price,
        start_time     => $contract->date_start->epoch,
        longcode       => $contract->longcode,
        shortcode      => $contract->shortcode,
        payout         => $trx->payout
    };

    if ($contract->is_spread) {
        $response->{stop_loss_level}   = $contract->stop_loss_level;
        $response->{stop_profit_level} = $contract->stop_profit_level;
        $response->{amount_per_point}  = $contract->amount_per_point;
    }

    return $response;
}

sub buy_contract_for_multiple_accounts {
    my $params = shift;

    my $client = $params->{client} // die "client should be authed when get here";
    my @result;

    my $tokens = $params->{args}{tokens} // [];

    return BOM::RPC::v3::Utility::create_error({
            code              => 'TooManyTokens',
            message_to_client => localize('Up to 100 tokens are allowed.')}) if scalar @$tokens > 100;

    my $token_list_res = _check_token_list($tokens);

    return +{result => $token_list_res->{result}} unless $token_list_res->{success};

    my ($contract, $response);
    # NOTE: we rely here on BOM::Product::Transaction to perform all the
    #       client validations like client_status and self_exclusion.

    my $source              = $params->{source};
    my $contract_parameters = $params->{contract_parameters};
    my $args                = $params->{args};
    my $payout              = $params->{payout};

    my $purchase_date = time;    # Purchase is considered to have happened at the point of request.
    $contract_parameters = BOM::RPC::v3::Contract::prepare_ask($contract_parameters);
    $contract_parameters->{landing_company} = $client->landing_company->short;
    my $amount_type = $contract_parameters->{amount_type};

    unless ( BOM::RPC::v3::Contract::pre_validate_start_expire_dates($contract_parameters) ) {
        warn __PACKAGE__
            . " buy_contract_for_multiple_accounts pre_validate_start_expire_dates failed, parameters: "
            . encode_json($contract_parameters);
        $response = BOM::RPC::v3::Utility::create_error({
            code              => 'ContractCreationFailure',
            message_to_client => BOM::Platform::Context::localize('Cannot create contract')});
        return $response if $response;
    }

    try {
        $contract = produce_contract($contract_parameters);
    }
    catch {
        warn __PACKAGE__ . " buy_contract_for_multiple_accounts produce_contract failed, parameters: " . encode_json($contract_parameters);
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize('Cannot create contract')});
    };
    return $response if $response;

    my $price = $args->{price};
    if (defined $amount_type and $amount_type eq 'stake') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize("Contract's stake amount is more than the maximum purchase price.")}
        ) if ($price < $contract_parameters->{amount});

        $price = $contract_parameters->{amount};
    }

    my $trx = BOM::Transaction->new({
        client   => $client,
        multiple => $token_list_res->{result},
        contract => $contract,
        price    => ($price || 0),
        (defined $payout)      ? (payout      => $payout)      : (),
        (defined $amount_type) ? (amount_type => $amount_type) : (),
        purchase_date => $purchase_date,
        source        => $source,
    });

    if (my $err = $trx->batch_buy) {
        return BOM::RPC::v3::Utility::create_error({
            code              => $err->get_type,
            message_to_client => $err->{-message_to_client},
        });
    }

    for my $el (@{$token_list_res->{result}}) {
        my $new = {};
        if (exists $el->{code}) {
            @{$new}{qw/token code message_to_client/} =
                @{$el}{qw/token code error/};
        } else {
            $new->{token}          = $el->{token};
            $new->{transaction_id} = $el->{txn}->{id};
            $new->{contract_id}    = $el->{fmb}->{id};
            $new->{purchase_time} =
                Date::Utility->new($el->{fmb}->{purchase_time})->epoch;
            $new->{buy_price} = $el->{fmb}->{buy_price};
            $new->{start_time} =
                Date::Utility->new($el->{fmb}->{start_time})->epoch;
            $new->{longcode}  = $contract->longcode;
            $new->{shortcode} = $el->{fmb}->{short_code};
            $new->{payout}    = $el->{fmb}->{payout_price};

            if ($contract->is_spread) {
                $new->{stop_loss_level}   = $contract->stop_loss_level;
                $new->{stop_profit_level} = $contract->stop_profit_level;
                $new->{amount_per_point}  = $contract->amount_per_point;
            }
        }
        $el = $new;
    }

    return +{result => $token_list_res->{result}};
}

sub _check_token_list {
    my $tokens = shift;

    my ($err, $result, $success, $m1, $m2) = (undef, [], 0, undef, undef);

    for my $t (@$tokens) {
        my $token_details = BOM::RPC::v3::Utility::get_token_details($t);
        my $loginid;

        if (    $token_details
            and $loginid = $token_details->{loginid}
            and grep({ /^trade$/ } @{$token_details->{scopes}}))
        {
            push @$result,
                +{
                token   => $t,
                loginid => $loginid,
                };
            $success = 1;
            next;
        }

        if ($loginid) {

            # here we got a valid token but with insufficient privileges
            push @$result,
                +{
                token             => $t,
                code              => 'PermissionDenied',
                message_to_client => ($m1 //= BOM::Platform::Context::localize('Permission denied, requires [_1] scope.', 'trade')),
                };
            next;

        }

        push @$result,
            +{
            token             => $t,
            code              => 'InvalidToken',
            message_to_client => ($m2 //= BOM::Platform::Context::localize('Invalid token')),
            };
    }

    return {
        success => $success,
        result  => $result
    };
}

sub sell_contract_for_multiple_accounts {
    my $params = shift;

    my $client = $params->{client} // die "client should be authed when get here";

    my ($source, $args) = ($params->{source}, $params->{args});

    my $shortcode = $args->{shortcode};

    my $tokens = $args->{tokens} // [];

    return BOM::RPC::v3::Utility::create_error({
            code              => 'TooManyTokens',
            message_to_client => localize('Up to 100 tokens are allowed.')}) if scalar @$tokens > 100;

    my $token_list_res = _check_token_list($tokens);

    return +{result => $token_list_res->{result}} unless $token_list_res->{success};

    my $contract_parameters = shortcode_to_parameters($shortcode, $client->currency);
    $contract_parameters->{landing_company} = $client->landing_company->short;
    my $contract = produce_contract($contract_parameters);

    my $trx = BOM::Transaction->new({
        client   => $client,
        multiple => $token_list_res->{result},
        contract => $contract,
        price    => ($args->{price} // 0),
        source   => $source,
    });

    if (my $err = $trx->sell_by_shortcode) {
        return BOM::RPC::v3::Utility::create_error({
            code              => $err->get_type,
            message_to_client => $err->{-message_to_client},
            message           => "Contract-Multi-Sell Fail: " . $err->get_type . " $err->{-message_to_client}: $err->{-mesg}"
        });
    }

    my $data_to_return = [];
    foreach my $row (@{$token_list_res->{result}}) {
        my $new = {};
        if (exists $row->{code}) {
            @{$new}{qw/token code message_to_client/} =
                @{$row}{qw/token code error/};
        } else {
            $new = +{
                transaction_id => $row->{buy_tr_id},
                balance_after  => sprintf('%.2f', $row->{tnx}{balance_after}),
                sell_price     => abs($row->{fmb}{sell_price}),
                contract_id    => $row->{tnx}{financial_market_bet_id},
                sell_time      => $row->{fmb}{sell_time},
            };
        }
        push @{$data_to_return}, $new;
    }

    return +{result => $data_to_return};
}

sub sell {
    my $params = shift;

    my $client = $params->{client} // die "client should be authed when get here";

    my ($source, $args) = ($params->{source}, $params->{args});
    my $id = $args->{sell};

    my $clientdb = BOM::Database::ClientDB->new({
        client_loginid => $client->loginid,
        operation      => 'replica',
    });

    my @fmbs = @{$clientdb->getall_arrayref('select * from bet_v1.get_open_contract_by_id(?)', [$id])};

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidSellContractProposal',
            message_to_client => BOM::Platform::Context::localize('Unknown contract sell proposal')}) unless @fmbs;

    my $contract_parameters =
        shortcode_to_parameters($fmbs[0]->{short_code}, $client->currency);
    $contract_parameters->{landing_company} = $client->landing_company->short;
    my $amount_type = $contract_parameters->{amount_type};
    my $contract    = produce_contract($contract_parameters);
    my $trx         = BOM::Transaction->new({
        client   => $client,
        contract => $contract,
        (defined $amount_type) ? (amount_type => $amount_type) : (),
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
        balance_after  => sprintf('%.2f', $trx->balance_after),
        sold_for       => abs($trx->amount),
    };
}

1;
