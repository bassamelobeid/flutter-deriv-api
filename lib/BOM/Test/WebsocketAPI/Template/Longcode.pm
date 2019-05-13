package BOM::Test::WebsocketAPI::Template::Longcode;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

rpc_request longcode => sub {
    my $shortcode = sprintf('%s_%s_20.43_1557198681_1557705599_S0P_0', $_->contract_type, $_->underlying->symbol);
    return {
        short_codes => $shortcode,
    };
    },
    qw(currency contract_type underlying);

rpc_response longcode => sub {
    my $shortcode = sprintf('%s_%s_20.43_1557198681_1557705599_S0P_0', $_->contract_type, $_->underlying->symbol);
    return {
        'longcodes' => {
            $shortcode => sprintf(
                'Win payout if %s is strictly %s than entry spot at close on 2019-04-29.',
                $_->underlying->display_name,
                $_->contract_type eq 'CALL' ? 'higher' : 'lower'
            )}};
};

1;
