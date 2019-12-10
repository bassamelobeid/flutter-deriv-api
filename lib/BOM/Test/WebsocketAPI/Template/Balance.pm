package BOM::Test::WebsocketAPI::Template::Balance;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request balance => sub {
    return balance => {balance => 1};
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
            account   => 'current',
            req_id    => 3,
            subscribe => 1
        },
        source  => '1',
        logging => {},
        token   => $_->client->token
    };
}
qw(client);

rpc_response {
    return {
        loginid    => $_->client->loginid,
        balance    => $_->client->balance,
        currency   => $_->client->currency,
        account_id => $_->client->account_id,
    };
};

publish transaction => sub {
    my $client = $_->client;

    my $account_id = $client->account_id;
    my $amount     = sprintf("%.2f", (rand(1000) - 500));
    my $action     = $amount < 0 ? 'withdrawal' : 'deposit';
    $client->balance += $amount;

    return {
        "TXNUPDATE::transaction_$account_id" => {
            balance_after  => $client->balance,
            action_type    => $action,
            currency_code  => $client->currency,
            loginid        => $client->loginid,
            amount         => $amount,
            id             => ++$_->global->{transaction_id},
            payment_remark => 'published by balance template'
        },
    };
};

1;
