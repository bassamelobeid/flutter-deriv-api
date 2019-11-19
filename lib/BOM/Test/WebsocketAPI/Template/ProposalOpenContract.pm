package BOM::Test::WebsocketAPI::Template::ProposalOpenContract;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

# No requests, buy subscribes to open contracts for us, or you can manually create a proposal_open_contract request

# with contract_id
rpc_request {
    return {
        source_bypass_verification => 0,
        source                     => '1',
        brand                      => 'binary',
        language                   => 'EN',
        country_code               => 'aq',
        logging                    => {},
        args                       => {
            req_id                 => 3,
            subscribe              => 1,
            contract_id            => $_->contract->contract_id,
            proposal_open_contract => 1
        },
        contract_id  => $_->contract->contract_id,
        token        => $_->contract->client->token,
        valid_source => '1'
    };
}
qw(contract);

# With contract_id, called from Binary::WebSocketAPI::v3::Wrapper::Pricer::send_proposal_open_contract_last_time
# This only works for contracts bought earlier in a test
rpc_request_new_contracts {
    return {
        logging => {},
        args    => {
            proposal_open_contract => 1,
            contract_id            => $_->contract->contract_id,
        },
        brand                      => 'binary',
        contract_id                => $_->contract->contract_id,
        token                      => $_->contract->client->token,
        source                     => '1',
        source_bypass_verification => 0,
        valid_source               => '1'
    };
}
qw(contract);

# Same as previous, but for poc subscription to all contracts
rpc_request_new_contracts {
    return {
        logging                    => {},
        args                       => {proposal_open_contract => 1},
        brand                      => 'binary',
        contract_id                => $_->contract->contract_id,
        token                      => $_->contract->client->token,
        source                     => '1',
        source_bypass_verification => 0,
        valid_source               => '1'
    };
}
qw(contract);

# without contract_id
rpc_request {
    return {
        logging => {},
        args    => {
            req_id                 => 2,
            proposal_open_contract => 1,
            subscribe              => 1
        },
        source                     => '1',
        country_code               => 'aq',
        token                      => $_->client->token,
        source_bypass_verification => 0,
        brand                      => 'binary',
        language                   => 'EN',
        valid_source               => '1'
    };
}
qw(client);

# without contract_id (contract_id is handled in Buy)
rpc_response {
    return {} unless $_->contract or exists $_->global->{contracts}{$_->client};

    my @contracts = $_->contract ? ($_->contract) : values $_->global->{contracts}{$_->client}->%*;
    my $poc;
    for my $contract (@contracts) {
        $poc->{$contract->contract_id} = {
            account_id          => $contract->client->account_id,
            is_settleable       => $contract->is_sold,
            is_path_dependent   => 0,
            longcode            => $contract->longcode,
            is_expired          => 0,
            date_start          => 1557282856,
            buy_price           => $contract->amount,
            purchase_time       => 1557282856,
            current_spot        => '7138.40',
            entry_tick          => '7141.03',
            contract_type       => $contract->contract_type,
            current_spot_time   => 1557282864,
            bid_price           => '9.36',
            date_settlement     => 1557791999,
            entry_spot          => '7141.03',
            profit              => '-0.64',
            entry_tick_time     => 1557282858,
            underlying          => $contract->underlying->symbol,
            currency            => $contract->client->currency,
            contract_id         => $contract->contract_id,
            is_forward_starting => 0,
            barrier_count       => 1,
            payout              => '20.43',
            is_sold             => $contract->is_sold,
            is_valid_to_sell    => $contract->is_sold ? 0 : 1,
            shortcode           => $contract->shortcode,
            display_name        => $contract->underlying->display_name,
            is_intraday         => 0,
            transaction_ids     => {
                buy => $contract->buy_tx_id,
                $contract->is_sold ? (sell => $contract->sell_tx_id) : (),
            },
            date_expiry       => $contract->date_expiry,
            barrier           => '7141.03',
            status            => $contract->is_sold ? 'sold' : 'open',
            profit_percentage => '-6.40',
            (
                $contract->is_sold
                ? (
                    exit_tick        => '7221.21',
                    validation_error => 'This contract has been sold.',
                    sell_price       => '9.36',
                    sell_time        => 1557290081,
                    exit_tick_time   => 1557290080,
                    sell_spot        => '7221.21',
                    sell_spot_time   => 1557290080,
                    audit_details    => {
                        contract_start => [{
                                tick  => '7142.84',
                                epoch => 1557282852
                            },
                            {
                                epoch => 1557282854,
                                tick  => '7141.57'
                            },
                            {
                                name  => 'Start Time',
                                epoch => 1557282856,
                                tick  => '7140.33',
                                flag  => 'highlight_time'
                            },
                            {
                                flag  => 'highlight_tick',
                                tick  => '7141.03',
                                epoch => 1557282858,
                                name  => 'Entry Spot'
                            },
                            {
                                tick  => '7139.89',
                                epoch => 1557282860
                            },
                            {
                                epoch => 1557282862,
                                tick  => '7139.37'
                            }]
                    },
                    )
                : ()
            ),
        };
    }
    return $poc;
};

# without contract_id (contract_id is handled in Buy)
publish proposal_open_contract => sub {
    return undef unless $_->client and exists $_->global->{contracts}{$_->client};

    my $poc;
    for my $contract (values $_->global->{contracts}{$_->client}->%*) {
        next if $contract->is_sold;
        my $payload = {
            sprintf('CONTRACT_PRICE::%s_%s', $contract->contract_id, $contract->client->landing_company_name) => {
                price_daemon_cmd    => 'bid',
                currency            => $contract->client->currency,
                rpc_time            => 31.425,
                date_settlement     => 1557791999,
                is_forward_starting => 0,
                is_settleable       => 0,
                shortcode           => $contract->shortcode,
                barrier_count       => 1,
                bid_price           => '9.36',
                contract_id         => $contract->contract_id,
                entry_tick          => '7141.03',
                longcode            => $contract->longcode,
                is_path_dependent   => 0,
                is_expired          => 0,
                display_name        => $contract->underlying->symbol,
                is_intraday         => 0,
                payout              => 20.43,
                entry_spot          => '7141.03',
                date_start          => 1557282856,
                current_spot        => '7138.40',
                current_spot_time   => 1557282864,
                entry_tick_time     => 1557282858,
                barrier             => '7141.03',
                underlying          => $contract->underlying->symbol,
                status              => 'open',
                is_valid_to_sell    => 1,
                date_expiry         => $contract->date_expiry,
                contract_type       => $contract->contract_type,
            },
        };
        push $poc->@*, $payload;
    }
    return $poc;
};

1;
