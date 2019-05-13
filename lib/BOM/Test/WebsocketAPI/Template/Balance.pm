package BOM::Test::WebsocketAPI::Template::Balance;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request balance => sub {
    return {balance => 1};
};

rpc_request balance => sub {
    return {balance => 1};
    },
    qw(client);

rpc_response balance => sub {
    return {
        'loginid'  => $_->client->loginid,
        'balance'  => $_->client->balance,
        'currency' => $_->client->currency
    };
};

1;
