package BOM::Test::WebsocketAPI::Template::Longcode;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

rpc_request longcode => sub {
    my $contract = $_->contract;
    return {
        'short_codes'                => [$contract->shortcode],
        'valid_source'               => '1',
        'source_bypass_verification' => 0,
        'language'                   => 'EN',
        'brand'                      => 'binary',
        'currency'                   => $contract->client->currency,
        'args'                       => {},
        'source'                     => '1',
        'logging'                    => {}};
    },
    qw(contract);

rpc_response longcode => sub {
    my $contract = $_->contract;
    return {
        longcodes => {$contract->shortcode => $contract->longcode},
    };
};

1;
