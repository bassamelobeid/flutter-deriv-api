package BOM::Test::WebsocketAPI::Template::Proposal;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request proposal => sub {
    return {
        proposal      => 1,
        amount        => 10,
        basis         => 'stake',
        contract_type => $_->contract_type,
        currency      => $_->currency,
        symbol        => $_->underlying->symbol,
        duration      => 5,
        duration_unit => 'd'
    };
    },
    qw(currency contract_type underlying);

rpc_request send_ask => sub {
    return {
        'basis'         => 'stake',
        'duration'      => 5,
        'product_type'  => 'basic',
        'proposal'      => 1,
        'symbol'        => $_->underlying->symbol,
        'duration_unit' => 'd',
        'contract_type' => $_->contract_type,
        'amount'        => 10,
        'currency'      => $_->currency,
    };
    },
    qw(currency country contract_type underlying);

rpc_response send_ask => sub {
    return {
        'spot'          => '78.602',
        'spot_time'     => '1556086356',
        'rpc_time'      => '1023.498',
        'display_value' => '10.00',
        'ask_price'     => '10.00',
        'longcode'      => sprintf(
            'Win payout if %s is strictly %s than entry spot at close on 2019-04-29.',
            $_->underlying->display_name,
            $_->contract_type eq 'CALL' ? 'higher' : 'lower'
        ),
        'payout'              => '17.65',
        'contract_parameters' => {
            'duration'              => '5d',
            'product_type'          => 'basic',
            'base_commission'       => '0.035',
            'subscribe'             => 1,
            'proposal'              => 1,
            'date_start'            => 0,
            'app_markup_percentage' => '0',
            'underlying'            => $_->underlying->symbol,
            'deep_otm_threshold'    => '0.05',
            'staking_limits'        => {
                'min' => '0.5',
                'max' => 20000
            },
            'amount'      => 10,
            'bet_type'    => $_->contract_type,
            'amount_type' => 'stake',
            'currency'    => $_->currency,
            'barrier'     => 'S0P'
        },
        'date_start' => '1556086356'
    };
};

publish proposal => sub {
    return {
        sprintf(
            'PRICER_KEYS::["amount","1000","basis","payout","contract_type","%s","country_code","%s","currency","%s","duration","5","duration_unit","d","landing_company",%s,"price_daemon_cmd","price","product_type","basic","proposal","1","skips_price_validation","1","subscribe","1","symbol","%s"]',
            $_->@{qw(contract_type country currency)},
            $_->country eq 'aq' ? 'null' : '"svg"',
            $_->underlying->symbol
            ) => {
            ask_price     => '566.27',
            date_start    => '1556174430',
            display_value => '566.27',
            longcode      => sprintf(
                'Win payout if %s is strictly %s than entry spot at close on 2019-04-30.',
                $_->underlying->display_name,
                $_->contract_type eq 'CALL' ? 'higher' : 'lower'
            ),
            payout           => '1000',
            price_daemon_cmd => 'price',
            rpc_time         => 51.094,
            spot             => '78.555',
            spot_time        => '1556174428',
            theo_probability => 0.531265531071756,
            }};
};

1;
