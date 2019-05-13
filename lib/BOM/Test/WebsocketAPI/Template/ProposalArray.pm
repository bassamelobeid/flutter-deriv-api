package BOM::Test::WebsocketAPI::Template::ProposalArray;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request proposal_array => sub {
    my $pa = $_->proposal_array->{$_->underlying->symbol};
    return {
        proposal_array => 1,
        basis          => 'stake',
        amount         => 10,
        currency       => $_->currency,
        symbol         => $_->underlying->symbol,
        duration       => 5,
        duration_unit  => 'd',
        contract_type  => [$pa->contract_types->@*],
        barriers       => [map { {barrier => $_} } $pa->barriers->@*],
    };
    },
    qw(currency proposal_array underlying);

rpc_request send_ask => sub {
    return {
        'currency'       => $_->currency,
        'contract_type'  => [$_->proposal_array->{$_->underlying->symbol}->contract_types->@*],
        'symbol'         => $_->underlying->symbol,
        'basis'          => 'stake',
        'proposal_array' => 1,
        'duration_unit'  => 'd',
        'amount'         => 10,
        'barriers'       => [$_->proposal_array->{$_->underlying->symbol}->barriers->@*],
        'duration'       => 5
    };
    },
    qw(currency country proposal_array underlying);

rpc_response send_ask => sub {
    my $symbol       = $_->underlying->symbol;
    my $display_name = $_->underlying->display_name;
    my $pa           = $_->proposal_array->{$symbol};
    return {
        'proposals' => {
            map {
                my $contract_type = $_;
                $contract_type => [
                    map { {
                            'display_value'    => 10,
                            'supplied_barrier' => $_,
                            'barrier'          => $_,
                            'theo_probability' => '' . rand,
                            'ask_price'        => 10,
                            'longcode'         => sprintf(
                                'Win payout if %s is strictly %s than %s at close on 2019-05-08.',
                                $display_name, $contract_type eq 'CALL' ? 'higher' : 'lower', $_
                            )}
                    } $pa->barriers->@*
                    ]
            } $pa->contract_types->@*
        },
        'contract_parameters' => {
            'subscribe'      => 1,
            'proposal_array' => 1,
            'date_start'     => 1556853241,
            'barriers'       => [
                map {
                    '' . $_
                } $pa->barriers->@*
            ],
            'app_markup_percentage' => '0',
            'currency'              => $_->currency,
            'base_commission'       => '0.015',
            'spot'                  => '6474.13',
            'staking_limits'        => {
                'max' => 50000,
                'min' => '0.35'
            },
            'duration'           => '5d',
            'spot_time'          => 1556853240,
            'amount'             => 10,
            'amount_type'        => 'stake',
            'underlying'         => $symbol,
            'bet_types'          => [$pa->contract_types->@*],
            'deep_otm_threshold' => '0.025'
        },
        'rpc_time' => '38.201'
    };
};

publish proposal_array => sub {
    my $symbol       = $_->underlying->symbol;
    my $display_name = $_->underlying->display_name;
    my $pa           = $_->proposal_array->{$symbol};
    return {
        sprintf(
            'PRICER_KEYS::["amount","1000","barriers",[%s],"basis","payout","contract_type",[%s],"country_code","%s","currency","%s","duration","5","duration_unit","d","landing_company",%s,"price_daemon_cmd","price","proposal_array","1","skips_price_validation","1","subscribe","1","symbol","%s"]',

            join(',', map { "\"$_\"" } $pa->barriers->@*),
            join(',', map { "\"$_\"" } $pa->contract_types->@*),
            $_->@{qw(country currency)},
            $_->country eq 'aq' ? 'null' : '"svg"',
            $_->underlying->symbol
            ) => {

            rpc_time  => 62.07,
            proposals => {
                map {
                    my $contract_type = $_;
                    $contract_type => [
                        map { {
                                'display_value'    => 10,
                                'supplied_barrier' => $_,
                                'barrier'          => $_,
                                'theo_probability' => rand,
                                'ask_price'        => 10,
                                'longcode'         => sprintf(
                                    'Win payout if %s is strictly %s than %s at close on 2019-05-08.',
                                    $display_name, $contract_type eq 'CALL' ? 'higher' : 'lower', $_
                                )}
                        } $pa->barriers->@*
                        ]
                } $pa->contract_types->@*
            },
            price_daemon_cmd => 'price'
            },
    };
};

1;
