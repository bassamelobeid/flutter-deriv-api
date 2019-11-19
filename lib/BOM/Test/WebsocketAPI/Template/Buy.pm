package BOM::Test::WebsocketAPI::Template::Buy;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;
use Date::Utility;

request buy => sub {
    my $contract = $_->contract;
    return buy => {
        buy        => 1,
        parameters => {
            symbol        => $contract->underlying->symbol,
            currency      => $contract->client->currency,
            amount        => $contract->amount,
            contract_type => $contract->contract_type,
            basis         => $contract->basis,
            duration      => $contract->duration,
            duration_unit => $contract->duration_unit,
        },
        price => $contract->amount
    };
    },
    qw(contract);

rpc_request {
    my $contract   = $_->contract;
    my $parameters = {
        app_markup_percentage => '0',
        currency              => $contract->client->currency,
        symbol                => $contract->underlying->symbol,
        amount                => $contract->amount,
        contract_type         => $contract->contract_type,
        basis                 => $contract->basis,
        duration              => $contract->duration,
        duration_unit         => $contract->duration_unit,
    };
    return {
        valid_source               => '1',
        source_bypass_verification => 0,
        contract_parameters        => $parameters,
        brand                      => 'binary',
        language                   => 'EN',
        token                      => $contract->client->token,
        logging                    => {},
        args                       => {
            parameters => $parameters,
            req_id     => 2,
            buy        => '1',
            subscribe  => 1,
            price      => $contract->amount,
        },
        source       => '1',
        country_code => 'aq'
    };
}
qw(contract);

rpc_response {
    my $contract = $_->contract;
    $_->global->{contracts}{$contract->client}{$contract} = $contract;
    my $contract_id = $contract->contract_id;
    my $tx_id       = $contract->buy_tx_id;
    return {
        purchase_time    => $contract->start_time,
        payout           => $contract->payout_str,
        contract_details => {
            buy_price       => $contract->amount_str,
            contract_id     => $contract_id,
            shortcode       => $contract->shortcode,
            currency        => $contract->client->currency,
            sell_time       => undef,
            purchase_time   => $contract->start_time,
            longcode        => $contract->longcode,
            transaction_ids => {
                buy => $tx_id,
            },
            sell_price => undef,
            account_id => $contract->client->account_id,
            is_sold    => 0
        },
        longcode       => $contract->longcode,
        transaction_id => $tx_id,
        shortcode      => $contract->shortcode,
        contract_id    => $contract_id,
        buy_price      => $contract->amount_str,
        start_time     => $contract->start_time,
        balance_after  => $contract->balance_after,
    };
};

# Required to make subscription work for buy
publish proposal_open_contract => sub {
    my $contract = $_->contract;
    return undef if $contract->is_sold;

    my $key = sprintf('CONTRACT_PRICE::%s_%s', $contract->contract_id, $contract->client->landing_company_name);
    return {
        $key => {
            price_daemon_cmd    => 'bid',
            currency            => $contract->client->currency,
            rpc_time            => 31.425,
            date_settlement     => $contract->date_expiry,
            is_forward_starting => 0,
            is_settleable       => 0,
            shortcode           => $contract->shortcode,
            barrier_count       => 1,
            bid_price           => $contract->bid_price_str,
            contract_id         => $contract->contract_id,
            entry_tick          => $contract->entry_tick,
            longcode            => $contract->longcode,
            is_path_dependent   => 0,
            is_expired          => 0,
            display_name        => $contract->underlying->symbol,
            is_intraday         => 0,
            payout              => $contract->payout,
            entry_spot          => $contract->entry_tick,
            date_start          => $contract->start_time,
            current_spot        => '7138.40',
            current_spot_time   => $contract->current_time,
            entry_tick_time     => $contract->start_time + 2,
            barrier             => $contract->entry_tick,
            underlying          => $contract->underlying->symbol,
            status              => $contract->status,
            is_valid_to_sell    => 1,
            date_expiry         => $contract->date_expiry,
            contract_type       => $contract->contract_type,
        }};
};

publish transaction => sub {
    my $contract    = $_->contract;
    my $action      = $contract->is_sold ? 'sell' : 'buy';
    my $account_id  = $contract->client->account_id;
    my $contract_id = $contract->contract_id;

    # publish just once each for buy and sell
    $_->global->{tx_published}{$action}{$contract_id}++;
    return if $_->global->{tx_published}{$action}{$contract_id} > 1;

    {
        "TXNUPDATE::transaction_$account_id" => {
            purchase_time           => $contract->start_time_dt->datetime_yyyymmdd_hhmmss,
            financial_market_bet_id => $contract_id,
            currency_code           => $contract->client->currency,
            transaction_time        => $contract->start_time_dt->datetime_yyyymmdd_hhmmss,
            short_code              => $contract->shortcode,
            payment_id              => '0',
            referrer_type           => 'financial_market_bet',
            action_type             => $action,
            # negative amount for buy, postive for sell
            amount => ($contract->is_sold ? 1 : -1) * $contract->amount,
            account_id     => $account_id,
            purchase_price => $contract->amount_str,
            payment_remark => "A $action transaction for testing",
            balance_after  => $contract->balance_after,
            id             => $contract->is_sold ? $contract->sell_tx_id : $contract->buy_tx_id,
            loginid        => $contract->client->loginid,
            sell_time      => $contract->is_sold ? Date::Utility->new->datetime_yyyymmdd_hhmmss : '',
        },
    };
};

1;
