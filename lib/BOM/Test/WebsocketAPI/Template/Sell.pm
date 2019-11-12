package BOM::Test::WebsocketAPI::Template::Sell;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;
use Date::Utility;

# this will only work for contracts bought earlier in the test
rpc_request_new_contracts {
    my $contract = $_->contract;

    return {
        valid_source               => '1',
        source_bypass_verification => 0,
        brand                      => 'binary',
        language                   => 'EN',
        token                      => $contract->client->token,
        logging                    => {},
        args                       => {
            req_id => 1,
            sell   => $contract->contract_id,
            price  => 0,
        },
        source       => '1',
        country_code => 'aq'
    };
};

rpc_response {
    my $contract = $_->contract;

    $contract->is_sold = 1;
    my $amount = $contract->amount;
    $contract->client->balance += $amount;

    return {
        transaction_id => $contract->sell_tx_id,
        reference_id   => $contract->buy_tx_id,
        contract_id    => $contract->contract_id,
        balance_after  => $contract->client->balance,
        sold_for       => $amount,
    };
};

# sell transaction is published in Buy template

1;
