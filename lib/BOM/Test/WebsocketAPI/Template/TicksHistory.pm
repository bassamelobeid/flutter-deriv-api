package BOM::Test::WebsocketAPI::Template::TicksHistory;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request ticks_history => sub {
    return {
        ticks_history => $_->underlying->symbol,
        end           => 'latest',
        style         => 'ticks',
        req_id        => ++$_->global->{req_id},
        count         => scalar($_->ticks_history->{$_->underlying->symbol}->times->@*),
    };
    },
    qw(underlying ticks_history);

rpc_request ticks_history => sub {
    return {
        'count'         => scalar($_->ticks_history->{$_->underlying->symbol}->times->@*),
        'end'           => 'latest',
        'ticks_history' => $_->underlying->symbol,
        'style'         => 'ticks',
    };
    },
    qw(underlying ticks_history);

rpc_response ticks_history => sub {
    my $now        = time;
    my $underlying = $_->underlying;
    my $pip_size   = log(1 / $underlying->pip_size) / log(10);

    return {
        'stash' => {
            $underlying->symbol . '_display_decimals' => $pip_size,
        },
        'data'    => {'history' => (map { {times => $_->times, prices => $_->prices} } $_->ticks_history->{$underlying->symbol})},
        'publish' => 'tick',
        'type'    => 'history'
    };
};

1;
