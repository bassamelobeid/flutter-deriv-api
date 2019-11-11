package BOM::Test::WebsocketAPI::Template::Tick;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request ticks => sub {
    return ticks => {
        ticks  => $_->underlying->symbol,
        req_id => ++$_->global->{req_id}};
    },
    qw(underlying);

rpc_request {
    return {
        logging                    => {},
        valid_source               => '1',
        brand                      => 'binary',
        source_bypass_verification => 0,
        symbol                     => $_->underlying->symbol,
        source                     => '1',
        args                       => {
            ticks  => $_->underlying->symbol,
            req_id => 2
        }};
}
qw(underlying);

rpc_response {
    my $pip_size = log(1 / $_->underlying->pip_size) / log(10);
    return {
        stash => {
            $_->underlying->symbol . _display_decimals => $pip_size,
        },
    };
};

publish tick => sub {
    my $symbol = $_->underlying->symbol;
    my $bid    = $_->underlying->pipsized_value(10 + (100 * rand));
    my $ask    = $_->underlying->pipsized_value(10 + (100 * rand));
    ($ask, $bid) = ($bid, $ask) unless $bid <= $ask;

    return {
        "DISTRIBUTOR_FEED::$symbol" => {
            symbol => $symbol,
            epoch  => time,
            bid    => $bid,
            ask    => $ask,
            quote  => $_->underlying->pipsized_value(($bid + $ask) / 2),
        },
    };
};

1;
