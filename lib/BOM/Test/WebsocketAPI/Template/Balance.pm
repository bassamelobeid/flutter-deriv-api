package BOM::Test::WebsocketAPI::Template::Balance;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request balance => sub {
    return {balance => 1};
};

rpc_request balance => sub {
    return {
        brand                      => 'binary',
        language                   => 'EN',
        source_bypass_verification => 0,
        valid_source               => '1',
        country_code               => 'aq',
        args                       => {
            balance   => 1,
            req_id    => 3,
            subscribe => 1
        },
        source  => '1',
        logging => {},
        token   => $_->client->token
    };
    },
    qw(client);

rpc_response balance => sub {
    return {
        loginid  => $_->client->loginid,
        balance  => $_->client->balance,
        currency => $_->client->currency
    };
};

1;
