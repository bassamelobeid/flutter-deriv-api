package BOM::Test::WebsocketAPI::Template::TicksHistory;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request ticks_history => sub {
    my $history = $_->ticks_history;
    return {
        ticks_history => $history->underlying->symbol,
        end           => 'latest',
        style         => 'ticks',
        req_id        => ++$_->global->{req_id},
        count         => scalar($history->times->@*),
    };
    },
    qw(ticks_history);

rpc_request ticks_history => sub {
    my $history = $_->ticks_history;
    return {
        logging                    => {},
        source_bypass_verification => 0,
        args                       => {
            count         => scalar($history->times->@*),
            end           => 'latest',
            ticks_history => $history->underlying->symbol,
            style         => 'ticks',
            req_id        => 2
        },
        source       => '1',
        valid_source => '1',
        brand        => 'binary'
    };
    },
    qw(ticks_history);

rpc_response ticks_history => sub {
    my $now        = time;
    my $history    = $_->ticks_history;
    my $underlying = $history->underlying;
    my $pip_size   = log(1 / $underlying->pip_size) / log(10);

    return {
        stash => {
            $underlying->symbol . _display_decimals => $pip_size,
        },
        data    => {history => (map { {times => $_->times, prices => $_->prices} } $history)},
        publish => 'tick',
        type    => 'history'
    };
};

1;
