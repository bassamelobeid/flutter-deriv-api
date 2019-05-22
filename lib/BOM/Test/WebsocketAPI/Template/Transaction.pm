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
        args => {
            transaction => 1,
        },
     shortcode => sprintf('%s_%s_20.43_1557198681_1557705599_S0P_0', $_->contract->contract_type, $_->contract->underlying->symbol)
    };
    },
    qw(contract);

rpc_response transaction => sub {
   
    my $contract = $_->contract;
    {
            'longcode'          => sprintf(
                'Win payout if %s is strictly %s than entry spot at close on 2019-04-29.',
                $contract->underlying->display_name,
                $contract->contract_type eq 'CALL' ? 'higher' : 'lower'
            ),
            'display_name' => $contract->underlying->display_name,
            'date_expiry' => 1557705599,
            'symbol' => $contract->underlying->symbol,
            barrier => 'S0P'
    }; };

1;
