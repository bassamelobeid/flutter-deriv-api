package BOM::Test::WebsocketAPI::Template::BalanceAll;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request balance_all => sub {
    return balance => {
        balance => 1,
        account => 'all'
    };
};

rpc_request {
    return {
        brand                      => 'binary',
        language                   => 'EN',
        source_bypass_verification => 0,
        valid_source               => '1',
        country_code               => 'aq',
        args                       => {
            balance   => 1,
            req_id    => 3,
            subscribe => 1,
            account   => 'all',
        },
        source     => '1',
        logging    => {},
        token      => $_->client->token,
        token_type => 'oauth_token',
    };
}
qw(client);

rpc_response {
    return {
        loginid    => $_->client->loginid,
        balance    => $_->client->balance,
        currency   => $_->client->currency,
        account_id => $_->client->account_id,
        total      => {
            deriv => {
                amount   => $_->client->total_balance,
                currency => $_->client->currency,
            },
        },
        accounts => {
            $_->client->loginid => {
                currency                        => $_->client->currency,
                balance                         => $_->client->balance,
                converted_amount                => $_->client->balance,
                account_id                      => $_->client->account_id,
                currency_rate_in_total_currency => 1,
                demo_account                    => 0,
                type                            => 'deriv',
            },
        },
    };
};

publish transaction => sub {
    my $client = $_->client;

    my $account_id = $client->account_id;
    my $amount     = sprintf("%.2f", (rand(1000) - 500));
    my $action     = $amount < 0 ? 'withdrawal' : 'deposit';
    $client->balance       += $amount;
    $client->total_balance += $amount;

    return {
        "TXNUPDATE::transaction_$account_id" => {
            balance_after  => $client->balance,
            action_type    => $action,
            currency_code  => $client->currency,
            loginid        => $client->loginid,
            amount         => $amount,
            id             => ++$_->global->{transaction_id},
            payment_remark => 'published by balance template',
            total          => {
                deriv => {
                    amount   => $client->total_balance,
                    currency => $client->currency,
                },
            },
        },
    };
};

1;

