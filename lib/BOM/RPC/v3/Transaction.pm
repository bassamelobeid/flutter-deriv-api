package BOM::RPC::v3::Transaction;

use strict;
use warnings;

use Try::Tiny;
use JSON::XS qw/encode_json/;
use Scalar::Util qw(blessed);

use Client::Account;
use Format::Util::Numbers qw/formatnumber/;

use BOM::RPC::v3::Contract;
use BOM::RPC::v3::Utility;
use BOM::RPC::v3::PortfolioManagement;
use BOM::Transaction;
use BOM::Platform::Context qw (localize request);
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Copier;

sub trade_copiers {
    my $params = shift;

    my $copiers = BOM::Database::DataMapper::Copier->new(
        broker_code => $params->{client}->broker_code,
        operation   => 'replica',
        )->get_trade_copiers({
            trader_id  => $params->{client}->loginid,
            trade_type => $params->{contract}{bet_type},
            asset      => $params->{contract}->underlying->symbol,
            price      => ($params->{price} || undef),
        });

    return unless $copiers && ref $copiers eq 'ARRAY' && scalar @$copiers;

    ### Note: this array of hashes will be modified by BOM::Transaction with the results per each client
    my @multiple = map { +{loginid => $_} } @$copiers;
    my $trx = BOM::Transaction->new({
        client   => $params->{client},
        multiple => \@multiple,
        contract => $params->{contract},
        price    => ($params->{price} || 0),
        source   => $params->{source},
        (defined $params->{payout})      ? (payout      => $params->{payout})      : (),
        (defined $params->{amount_type}) ? (amount_type => $params->{amount_type}) : (),
        purchase_date => $params->{purchase_date},
    });

    $params->{action} eq 'buy' ? $trx->batch_buy : $trx->sell_by_shortcode;

    return 1;
}

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
    $contract_parameters->{binaryico_deposit_percentage} =
        BOM::Platform::Runtime->instance->app_config->system->suspend->ico_initial_deposit_percentage
        if $contract_parameters->{contract_type} eq 'BINARYICO';
    my $amount_type = $contract_parameters->{amount_type};
    my $response;

    my $price = $args->{price};
    if (defined $price and defined $contract_parameters->{amount} and defined $amount_type and $amount_type eq 'stake') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize("Contract's stake amount is more than the maximum purchase price.")}
        ) if ($price < $contract_parameters->{amount});
        $price = $contract_parameters->{amount};
    }

    my $trx = BOM::Transaction->new({
            client              => $client,
            contract_parameters => $contract_parameters,
            price               => ($price || 0),
            (defined $payout)      ? (payout      => $payout)      : (),
            (defined $amount_type) ? (amount_type => $amount_type) : (),
            purchase_date => $purchase_date,
            source        => $source,
            (defined $trading_period_start)
            ? (trading_period_start => $trading_period_start)
            : (),
        });

    try {
        if (my $err = $trx->buy) {
            $response = BOM::RPC::v3::Utility::create_error({
                code              => $err->get_type,
                message_to_client => $err->{-message_to_client},
            });
        }
    }
    catch {
        my $message_to_client;
        if (blessed($_) && $_->isa('BOM::Product::Exception')) {
            $message_to_client = $_->message_to_client;
        } else {
            $message_to_client = ['Cannot create contract'];
            warn __PACKAGE__ . " buy failed: '$_', parameters: " . encode_json($contract_parameters);
        }
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize(@$message_to_client)});
    };
    return $response if $response;

    try {
        trade_copiers({
                action        => 'buy',
                client        => $client,
                contract      => $trx->contract,
                price         => $price,
                payout        => $payout,
                amount_type   => $amount_type,
                purchase_date => $purchase_date,
                source        => $source
            }) if $client->allow_copiers;
    }
    catch {
        warn "Copiers trade error: " . $_;
    };

    $response = {
        transaction_id => $trx->transaction_id,
        contract_id    => $trx->contract_id,
        balance_after  => formatnumber('amount', $client->currency, $trx->balance_after),
        purchase_time  => $trx->purchase_date->epoch,
        buy_price      => formatnumber('amount', $client->currency, $trx->price),
        start_time     => $trx->contract->date_start->epoch,
        longcode       => localize($trx->contract->longcode),
        shortcode      => $trx->contract->shortcode,
        payout         => $trx->payout
    };

    return $response;
}

sub buy_contract_for_multiple_accounts {
    my $params = shift;

    my $client = $params->{client} // die "client should be authed when get here";

    return BOM::RPC::v3::Utility::create_error({
            code              => 'IcoOnlyAccount',
            message_to_client => BOM::Platform::Context::localize('This is not supported on an ICO-only account.')}
    ) if $client->get_status('ico_only');

    my $tokens = $params->{args}{tokens} // [];

    return BOM::RPC::v3::Utility::create_error({
            code              => 'TooManyTokens',
            message_to_client => localize('Up to 100 tokens are allowed.')}) if scalar @$tokens > 100;

    my $token_list_res = _check_token_list($tokens);

    return +{result => $token_list_res->{result}} unless $token_list_res->{success};

    my $response;
    my $source              = $params->{source};
    my $contract_parameters = $params->{contract_parameters};
    my $args                = $params->{args};
    my $payout              = $params->{payout};

    my $purchase_date = time;    # Purchase is considered to have happened at the point of request.
    $contract_parameters = BOM::RPC::v3::Contract::prepare_ask($contract_parameters);
    $contract_parameters->{landing_company} = $client->landing_company->short;
    my $amount_type = $contract_parameters->{amount_type};

    my $price = $args->{price};
    if (defined $amount_type and $amount_type eq 'stake') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize("Contract's stake amount is more than the maximum purchase price.")}
        ) if ($price < $contract_parameters->{amount});

        $price = $contract_parameters->{amount};
    }

    my $trx = BOM::Transaction->new({
        client              => $client,
        multiple            => $token_list_res->{result},
        contract_parameters => $contract_parameters,
        price               => ($price || 0),
        (defined $payout)      ? (payout      => $payout)      : (),
        (defined $amount_type) ? (amount_type => $amount_type) : (),
        purchase_date => $purchase_date,
        source        => $source,
    });

    try {
        if (my $err = $trx->batch_buy) {
            $response = BOM::RPC::v3::Utility::create_error({
                code              => $err->get_type,
                message_to_client => $err->{-message_to_client},
            });
        }
    }
    catch {
        warn __PACKAGE__
            . " buy_contract_for_multiple_accounts failed with error [$_], parameters: "
            . (eval { encode_json($contract_parameters) } // 'could not encode, ' . $@);
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize('Cannot create contract')});
    };
    return $response if $response;

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
            $new->{longcode}  = localize($trx->contract->longcode);
            $new->{shortcode} = $el->{fmb}->{short_code};
            $new->{payout}    = $el->{fmb}->{payout_price};
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

    return BOM::RPC::v3::Utility::create_error({
            code              => 'IcoOnlyAccount',
            message_to_client => BOM::Platform::Context::localize('This is not supported on an ICO-only account.')}
    ) if $client->get_status('ico_only');

    my ($source, $args) = ($params->{source}, $params->{args});

    my $shortcode = $args->{shortcode};

    my $tokens = $args->{tokens} // [];

    return BOM::RPC::v3::Utility::create_error({
            code              => 'TooManyTokens',
            message_to_client => localize('Up to 100 tokens are allowed.')}) if scalar @$tokens > 100;

    my $token_list_res = _check_token_list($tokens);

    return +{result => $token_list_res->{result}} unless $token_list_res->{success};

    my $contract_parameters = {
        shortcode => $shortcode,
        currency  => $client->currency
    };
    $contract_parameters->{landing_company} = $client->landing_company->short;

    my $trx = BOM::Transaction->new({
        purchase_date       => Date::Utility->new(),
        client              => $client,
        multiple            => $token_list_res->{result},
        contract_parameters => $contract_parameters,
        price               => ($args->{price} // 0),
        source              => $source,
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
                transaction_id => $row->{tnx}{id},
                reference_id   => $row->{buy_tr_id},
                balance_after  => formatnumber('amount', $client->currency, $row->{tnx}{balance_after}),
                sell_price     => formatnumber('price', $client->currency, $row->{fmb}{sell_price}),
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

    my $contract_parameters = {
        shortcode => $fmbs[0]->{short_code},
        currency  => $client->currency
    };
    $contract_parameters->{landing_company} = $client->landing_company->short;
    my $purchase_date = time;
    my $trx           = BOM::Transaction->new({
        purchase_date       => $purchase_date,
        client              => $client,
        contract_parameters => $contract_parameters,
        contract_id         => $id,
        price               => ($args->{price} || 0),
        source              => $source,
    });

    if (my $err = $trx->sell) {
        return BOM::RPC::v3::Utility::create_error({
            code              => $err->get_type,
            message_to_client => $err->{-message_to_client},
            message           => "Contract-Sell Fail: " . $err->get_type . " $err->{-message_to_client}: $err->{-mesg}"
        });
    }

    try {
        trade_copiers({
                action        => 'sell',
                client        => $client,
                contract      => $trx->contract,
                price         => $args->{price},
                source        => $source,
                purchase_date => $purchase_date,
            }) if $client->allow_copiers;
    }
    catch {
        warn "Copiers trade error: " . $_;
    };

    my $trx_rec = $trx->transaction_record;

    return {
        transaction_id => $trx->transaction_id,
        reference_id   => $trx->reference_id,                                                   ### buy transaction ID
        contract_id    => $id,
        balance_after  => formatnumber('amount', $client->currency, $trx_rec->balance_after),
        sold_for       => formatnumber('price', $client->currency, $trx_rec->amount),
    };
}

1;
