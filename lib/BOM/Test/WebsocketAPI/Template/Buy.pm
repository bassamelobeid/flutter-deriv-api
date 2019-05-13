package BOM::Test::WebsocketAPI::Template::Buy;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request buy => sub {
    return {
        'buy'        => 1,
        'parameters' => {
            'symbol'        => $_->contract->underlying->symbol,
            'amount'        => 0 + $_->contract->amount,
            'currency'      => $_->contract->client->currency,
            'contract_type' => $_->contract->contract_type,
            'basis'         => 'stake',
            'duration'      => 5,
            'duration_unit' => 'd'
        },
        'price' => 0 + $_->contract->amount
    };
    },
    qw(contract);

rpc_request buy => sub {
    return {
        'parameters' => {
            'basis'                 => 'stake',
            'duration_unit'         => 'd',
            'amount'                => 0 + $_->contract->amount,
            'duration'              => 5,
            'contract_type'         => $_->contract->contract_type,
            'app_markup_percentage' => '0',
            'currency'              => $_->contract->client->currency,
            'symbol'                => $_->contract->underlying->symbol
        },
        'price' => 0 + $_->contract->amount,
        'buy'   => 1
    };
    },
    qw(contract);

rpc_response buy => sub {
    my $contract = $_->contract;
    $_->global->{contracts}{$contract->client}{$contract} = $contract;
    my $contract_id = $contract->contract_id;
    my $tx_id       = $contract->buy_tx_id;
    return {
        'purchase_time'    => 1557198681,
        'payout'           => '20.43',
        'contract_details' => {
            'buy_price'     => $contract->amount,
            'contract_id'   => $contract_id,
            'shortcode'     => sprintf('%s_%s_20.43_1557198681_1557705599_S0P_0', $contract->contract_type, $contract->underlying->symbol),
            'currency'      => $contract->client->currency,
            'sell_time'     => undef,
            'purchase_time' => 1557198681,
            'longcode'      => sprintf(
                'Win payout if %s is strictly %s than entry spot at close on 2019-04-29.',
                $contract->underlying->display_name,
                $contract->contract_type eq 'CALL' ? 'higher' : 'lower'
            ),
            'transaction_ids' => {
                'buy' => $tx_id,
            },
            'sell_price' => undef,
            'account_id' => $contract->client->account_id,
            'is_sold'    => 0
        },
        'longcode' => sprintf(
            'Win payout if %s is strictly %s than entry spot at close on 2019-04-29.',
            $contract->underlying->display_name,
            $contract->contract_type eq 'CALL' ? 'higher' : 'lower'
        ),
        'transaction_id' => $tx_id,
        'shortcode'      => sprintf('%s_%s_20.43_1557198681_1557705599_S0P_0', $contract->contract_type, $contract->underlying->symbol),
        'contract_id'    => $contract_id,
        'buy_price'      => $contract->amount,
        'start_time'     => 1557198681,
        'balance_after'  => $contract->balance_after,
    };
};

# Required to make subscription work for buy
publish proposal_open_contract => sub {
    my $contract = $_->contract;
    return undef if $contract->is_sold;

    my $shortcode = sprintf('%s_%s_20.43_1557198681_1557705599_S0P_0', $contract->contract_type, $contract->underlying->symbol);
    my $key = sprintf(
        'PRICER_KEYS::["short_code","%s","contract_id","%s","country_code","%s","currency","%s","is_sold","0","landing_company","%s","price_daemon_cmd","bid","sell_time",null]',

        $shortcode,
        $contract->contract_id,
        $contract->client->country,
        $contract->client->currency,
        $contract->client->landing_company_name,
    );
    return {
        $key => {
            price_daemon_cmd    => 'bid',
            currency            => $contract->client->currency,
            rpc_time            => 31.425,
            date_settlement     => 1557791999,
            is_forward_starting => 0,
            is_settleable       => 0,
            shortcode           => $shortcode,
            barrier_count       => 1,
            bid_price           => '9.36',
            contract_id         => $contract->contract_id,
            entry_tick          => '7141.03',
            'longcode'          => sprintf(
                'Win payout if %s is strictly %s than entry spot at close on 2019-04-29.',
                $contract->underlying->display_name,
                $contract->contract_type eq 'CALL' ? 'higher' : 'lower'
            ),
            is_path_dependent => 0,
            is_expired        => 0,
            display_name      => $contract->underlying->symbol,
            is_intraday       => 0,
            payout            => 20.43,
            entry_spot        => '7141.03',
            date_start        => 1557282856,
            current_spot      => '7138.40',
            current_spot_time => 1557282864,
            entry_tick_time   => 1557282858,
            barrier           => '7141.03',
            underlying        => $contract->underlying->symbol,
            status            => 'open',
            is_valid_to_sell  => 1,
            date_expiry       => 1557791999,
            contract_type     => $contract->contract_type,
        }};
};

# Publish sell transaction after 5 times
my $sell_at = 5;
publish transaction => sub {
    my $contract = $_->contract;
    return undef if $contract->is_sold;
    my $account_id = $contract->client->account_id;

    my $tx_published = $_->global->{tx_published}{$contract} //= {};
    $tx_published->{count}++;

    if ($tx_published->{count} == 1) {
        # Buy
    } elsif ($tx_published->{count} == $sell_at) {
        # Sell
        $contract->is_sold = 1;
    } else {
        # No Data
        delete $_->global->{tx_published}{$contract};
        return undef;
    }

    my $action = $contract->is_sold ? 'sell' : 'buy';

    {
        "TXNUPDATE::transaction_$account_id" => {
            purchase_time           => '2019-05-08 07:16:52',
            financial_market_bet_id => $contract->contract_id,
            currency_code           => $contract->client->currency,
            transaction_time        => '2019-05-08 07:16:52.730054',
            short_code              => sprintf('%s_%s_20.43_1557198681_1557705599_S0P_0', $contract->contract_type, $contract->underlying->symbol),
            payment_id              => '0',
            referrer_type           => 'financial_market_bet',
            action_type             => $action,

            amount => ($contract->is_sold ? -1 : 1) * $contract->amount,
            account_id     => $contract->client->account_id,
            purchase_price => $contract->amount,
            payment_remark => "A $action transaction for testing",
            balance_after  => $contract->balance_after,
            id             => $contract->is_sold ? $contract->sell_tx_id : $contract->buy_tx_id,
            loginid        => $contract->client->loginid,
            sell_time      => $contract->is_sold ? '2019-05-08 07:16:52.730054' : '',
        },
    };
};

1;
