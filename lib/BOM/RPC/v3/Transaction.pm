package BOM::RPC::v3::Transaction;

use strict;
use warnings;

use Try::Tiny;
use Encode;
use JSON::MaybeXS;
use Scalar::Util qw(blessed);
use Time::HiRes qw();

use Format::Util::Numbers qw/formatnumber financialrounding/;

use BOM::RPC::Registry '-dsl';

use BOM::RPC::v3::Contract;
use BOM::RPC::v3::Utility;
use BOM::RPC::v3::PortfolioManagement;
use BOM::Transaction;
use BOM::Platform::Context qw (localize request);
use BOM::Config::Runtime;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Copier;
use BOM::Pricing::v3::Contract;
use Finance::Contract::Longcode qw(shortcode_to_longcode);

my $json = JSON::MaybeXS->new;

requires_auth();

my $nonbinary_list = 'LBFLOATCALL|LBFLOATPUT|LBHIGHLOW';

sub trade_copiers {
    my $params = shift;

    my $copiers = BOM::Database::DataMapper::Copier->new(
        broker_code => $params->{client}->broker_code,
        operation   => 'replica',
        )->get_trade_copiers({
            trader_id  => $params->{client}->loginid,
            trade_type => $params->{contract}{bet_type},
            asset      => $params->{contract}->underlying->symbol,
            # copier's min/max price condition is ignored for sell
            price => $params->{action} eq 'buy' && $params->{price} ? $params->{price} : undef,
        });

    return unless $copiers && ref $copiers eq 'ARRAY' && scalar @$copiers;

    ### Note: this array of hashes will be modified by BOM::Transaction with the results per each client
    my @multiple = map { +{loginid => $_} } @$copiers;
    my $trx = BOM::Transaction->new({
        client   => $params->{client},
        multiple => \@multiple,
        $params->{action} eq 'buy' ? (contract => $params->{contract}) : (contract_parameters => $params->{contract_parameters}),
        price => ($params->{price} || 0),
        source => $params->{source},
        (defined $params->{payout})      ? (payout      => $params->{payout})      : (),
        (defined $params->{amount_type}) ? (amount_type => $params->{amount_type}) : (),
        purchase_date => $params->{purchase_date},
    });

    my $err = $params->{action} eq 'buy' ? $trx->batch_buy : $trx->sell_by_shortcode;
    die $err->get_type . " - $err->{-message_to_client}: $err->{-mesg}" if $err;

    return 1;
}

sub _validate_price {
    my ($price, $currency) = @_;

    if (defined $price) {
        my $num_of_decimals = Format::Util::Numbers::get_precision_config()->{price}->{$currency};
        my ($precision) = $price =~ /\.(\d+)/;
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidPrice',
                message_to_client => localize('Invalid price. Price provided can not have more than [_1] decimal places.', $num_of_decimals)}
        ) if ($precision and length($precision) > $num_of_decimals);
    }

    return undef;
}

sub _validate_currency {
    my ($client) = @_;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'NoCurrencySet',
            message_to_client => localize('Please set the currency of your account.')}) if (not $client->default_account);
    return undef;
}

sub _validate_amount {
    my ($amount, $currency) = @_;

    if (defined $amount) {
        my $num_of_decimals = Format::Util::Numbers::get_precision_config()->{amount}->{$currency};
        my ($precision) = $amount =~ /\.(\d+)/;
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidAmount',
                message_to_client => localize('Invalid amount. Amount provided can not have more than [_1] decimal places.', $num_of_decimals)}
        ) if ($precision and length($precision) > $num_of_decimals);
    }

    return undef;
}

sub _validate_stake {
    my ($price, $amount, $currency) = @_;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'ContractCreationFailure',
            message_to_client => BOM::Platform::Context::localize("Contract's stake amount is more than the maximum purchase price.")}
    ) if (financialrounding('price', $currency, $price) < financialrounding('amount', $currency, $amount));

    return undef;
}

rpc buy => sub {
    my $params = shift;

    my $tv = [Time::HiRes::gettimeofday];
    my $client = $params->{client} // die "Client should have been authenticated at this stage.";

    my ($source, $contract_parameters, $args, $payout) = @{$params}{qw/source contract_parameters args payout/};

    my $trading_period_start = $contract_parameters->{trading_period_start};
    my $purchase_date        = time;                                           # Purchase is considered to have happened at the point of request.

    $contract_parameters = BOM::Pricing::v3::Contract::prepare_ask($contract_parameters);
    $contract_parameters->{landing_company} = $client->landing_company->short;

    my $error = BOM::RPC::v3::Contract::validate_barrier($contract_parameters);
    return $error if $error->{error};

    $error = _validate_currency($client);
    return $error if $error;

    my $currency = $client->currency;
    my $price    = $args->{price};

    $error = _validate_price($price, $currency);
    return $error if $error;

    my ($amount, $amount_type) = @{$contract_parameters}{qw/amount amount_type/};

    #Temporary fix to skip amount validation for lookback.
    $error = _validate_amount($amount, $currency) if ($contract_parameters->{bet_type} and $contract_parameters->{bet_type} !~ /$nonbinary_list/);
    return $error if $error;

    if (defined $price and defined $amount and defined $amount_type and $amount_type eq 'stake') {
        $error = _validate_stake($price, $amount, $currency);
        return $error if $error;

        $price = $amount;
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
            $error = BOM::RPC::v3::Utility::create_error({
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
            warn __PACKAGE__ . " buy failed: '$_', parameters: " . $json->encode($contract_parameters);
        }
        $error = BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize(@$message_to_client)});
    };
    return $error if $error;

    my $contract = $trx->contract;

    if ($client->allow_copiers) {
        try {
            trade_copiers({
                action              => 'buy',
                client              => $client,
                contract_parameters => $contract_parameters,
                contract            => $contract,
                price               => $price,
                payout              => $payout,
                amount_type         => $amount_type,
                purchase_date       => $purchase_date,
                source              => $source
            });
        }
        catch {
            warn "Copiers trade buy error: " . $_;
        };
    }

    # to subscribe to this contract after buy, we need to have the same information that we pass to
    # proposal_open_contract call, so we are giving this information as part of the response here
    # but this will be removed at the websocket api logic before we show the response to the client.
    my $transaction_details = $trx->transaction_details;
    my $contract_details    = $trx->contract_details;

    # this will be passed to proposal_open_contract at websocket level
    # if subscription flag is turned on
    my $contract_proposal_details = {
        account_id      => $transaction_details->{account_id},
        shortcode       => $contract_details->{short_code},
        contract_id     => $contract_details->{id},
        currency        => $currency,
        buy_price       => $contract_details->{buy_price},
        sell_price      => $contract_details->{sell_price},
        sell_time       => $contract_details->{sell_time},
        purchase_time   => $trx->purchase_date->epoch,
        is_sold         => $contract_details->{is_sold},
        transaction_ids => {buy => $transaction_details->{id}},
        longcode        => localize(shortcode_to_longcode($contract_details->{short_code})),
    };

    return {
        transaction_id   => $trx->transaction_id,
        contract_id      => $trx->contract_id,
        contract_details => $contract_proposal_details,
        balance_after    => formatnumber('amount', $currency, $trx->balance_after),
        purchase_time    => $trx->purchase_date->epoch,
        buy_price        => formatnumber('amount', $currency, $trx->price),
        start_time       => $contract->date_start->epoch,
        longcode         => localize($contract->longcode),
        shortcode        => $contract->shortcode,
        payout           => $trx->payout,
        stash    => {market => $contract->market->name},
        rpc_time => 1000 * Time::HiRes::tv_interval($tv),
    };
};

rpc buy_contract_for_multiple_accounts => sub {
    my $params = shift;

    my $client = $params->{client} // die "Client should have been authenticated at this stage.";

    my $args = $params->{args};
    my $tokens = $args->{tokens} // [];

    # Validation still needs to be done on the client that instigated the rpc call
    # Reason: Compliance checks to prevent money laundering, scamming, fraudulent, etc
    my $validation_error = BOM::RPC::v3::Utility::validation_checks($client);
    return $validation_error if $validation_error;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'TooManyTokens',
            message_to_client => localize('Up to 100 tokens are allowed.')}) if scalar @$tokens > 100;

    my $token_list_res = _check_token_list($tokens);

    return +{result => $token_list_res->{result}} unless $token_list_res->{success};

    my ($source, $contract_parameters, $payout) = @{$params}{qw/source contract_parameters payout/};

    my $purchase_date = time;    # Purchase is considered to have happened at the point of request.
    $contract_parameters = BOM::Pricing::v3::Contract::prepare_ask($contract_parameters);
    $contract_parameters->{landing_company} = $client->landing_company->short;

    my $error = BOM::RPC::v3::Contract::validate_barrier($contract_parameters);
    return $error if $error->{error};

    $error = _validate_currency($client);
    return $error if $error;

    my $price    = $args->{price};
    my $currency = $client->currency;

    $error = _validate_price($price, $currency);
    return $error if $error;

    my ($amount, $amount_type) = @{$contract_parameters}{qw/amount amount_type/};

    $error = _validate_amount($amount, $currency) if ($contract_parameters->{bet_type} !~ /$nonbinary_list/);
    return $error if $error;

    if (defined $price and defined $amount and defined $amount_type and $amount_type eq 'stake') {
        $error = _validate_stake($price, $amount, $currency);
        return $error if $error;

        $price = $amount;
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
            $error = BOM::RPC::v3::Utility::create_error({
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
            warn __PACKAGE__
                . " buy_contract_for_multiple_accounts failed with error [$_], parameters: "
                . (eval { $json->encode($contract_parameters) } // 'could not encode, ' . $@);
        }
        $error = BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize(@$message_to_client)});
    };
    return $error if $error;

    for my $el (@{$token_list_res->{result}}) {
        my $new = {};
        if (exists $el->{code}) {
            @{$new}{qw/token code message_to_client/} =
                @{$el}{qw/token code message_to_client/};
        } else {
            my $fmb = $el->{fmb};

            $new->{token}          = $el->{token};
            $new->{transaction_id} = $el->{txn}->{id};
            $new->{contract_id}    = $fmb->{id};
            $new->{purchase_time} =
                Date::Utility->new($fmb->{purchase_time})->epoch;
            $new->{buy_price} = $fmb->{buy_price};
            $new->{start_time} =
                Date::Utility->new($fmb->{start_time})->epoch;
            $new->{longcode}  = localize($trx->contract->longcode);
            $new->{shortcode} = $fmb->{short_code};
            $new->{payout}    = $fmb->{payout_price};
        }
        $el = $new;
    }

    return +{result => $token_list_res->{result}};
};

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

rpc sell_contract_for_multiple_accounts => sub {
    my $params = shift;

    my $client = $params->{client} // die "client should be authed when get here";

    # Validation still needs to be done on the client that instigated the rpc call
    # Reason: Compliance checks to prevent money laundering, scamming, fraudulent, etc
    my $validation_error = BOM::RPC::v3::Utility::validation_checks($client);
    return $validation_error if $validation_error;

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
                @{$row}{qw/token code message_to_client/};
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
};

rpc sell => sub {
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
                action              => 'sell',
                client              => $client,
                contract_parameters => $contract_parameters,
                contract            => $trx->contract,
                price               => $args->{price},
                source              => $source,
                purchase_date       => $purchase_date,
            }) if $client->allow_copiers;
    }
    catch {
        warn "Copiers trade sell error: " . $_;
    };

    my $trx_rec = $trx->transaction_record;

    return {
        transaction_id => $trx->transaction_id,
        reference_id   => $trx->reference_id,                                                   ### buy transaction ID
        contract_id    => $id,
        balance_after  => formatnumber('amount', $client->currency, $trx_rec->balance_after),
        sold_for       => formatnumber('price', $client->currency, $trx_rec->amount),
    };
};

1;
