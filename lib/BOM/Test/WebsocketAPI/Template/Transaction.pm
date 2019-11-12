package BOM::Test::WebsocketAPI::Template::Transaction;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request transaction => sub {
    return transaction => {
        transaction => 1,
    };
};

rpc_request {
    my $contract = $_->contract;
    return {
        currency                   => $contract->client->currency,
        short_code                 => $contract->shortcode,
        source_bypass_verification => 0,
        source                     => '1',
        brand                      => 'binary',
        landing_company            => $contract->client->landing_company_name,
        token                      => $contract->client->token,
        args                       => {
            req_id      => 4,
            subscribe   => 1,
            transaction => 1
        },
        valid_source => '1',
        language     => 'EN',
        logging      => {},
    };
}
qw(contract);

rpc_response {
    my $contract = $_->contract;
    {
        longcode     => $contract->longcode,
        display_name => $contract->underlying->display_name,
        date_expiry  => $contract->date_expiry,
        symbol       => $contract->underlying->symbol,
        barrier      => $contract->barrier
    };
};

# Cannot publish, because there is no RPC request for this API call

1;
