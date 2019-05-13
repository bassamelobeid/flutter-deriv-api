package BOM::Test::WebsocketAPI::Template::Transaction;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request transaction => sub {
    return {
        transaction => 1,
    };
};

rpc_request transaction => sub {
    return {
        transaction => 1,
    };
    },
    qw(client);

rpc_response transaction => sub { {}; };

1;
