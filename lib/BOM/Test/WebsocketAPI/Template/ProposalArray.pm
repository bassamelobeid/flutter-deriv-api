package BOM::Test::WebsocketAPI::Template::ProposalArray;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

#request proposal_array => sub {
#    my $pa = $_->proposal_array;
#    return {
#        proposal_array => 1,
#        symbol         => $pa->underlying->symbol,
#        contract_type  => [$pa->contract_types->@*],
#        barriers       => [map { {barrier => $_} } $pa->barriers->@*],
#        basis          => $pa->basis,
#        amount         => $pa->amount,
#        currency       => $pa->client->currency,
#        duration       => $pa->duration,
#        duration_unit  => $pa->duration_unit,
#    };
#    },
#    qw(proposal_array);

rpc_request send_ask => sub {
    my $pa = $_->proposal_array;
    return {
        proposal_array             => 1,
        brand                      => 'binary',
        landing_company            => $pa->client->landing_company_name,
        app_markup_percentage      => '0',
        source                     => '1',
        source_bypass_verification => 0,
        logging                    => {},
        country_code               => 'aq',
        language                   => 'EN',
        valid_source               => '1',
        token                      => $pa->client->token,
        args                       => {
            currency       => $pa->client->currency,
            contract_type  => [$pa->contract_types->@*],
            symbol         => $pa->underlying->symbol,
            basis          => 'stake',
            proposal_array => 1,
            duration_unit  => 'd',
            amount         => 10,
            barriers       => [$pa->barriers->@*],
            req_id         => 3,
            subscribe      => 1,
            duration       => 5
        },
    };
    },
    qw(proposal_array);

rpc_response send_ask => sub {
    my $pa           = $_->proposal_array;
    my $symbol       = $pa->underlying->symbol;
    my $display_name = $pa->underlying->display_name;
    my $now          = time;
    return {
        proposals => {
            map {
                my $contract_type = $_;
                $contract_type => [
                    map { {
                            display_value    => 10,
                            supplied_barrier => $_,
                            barrier          => $_,
                            theo_probability => '' . rand,
                            ask_price        => 10,
                            longcode         => $pa->longcodes->{$contract_type}{$_}}
                    } $pa->barriers->@*
                    ]
            } $pa->contract_types->@*
        },
        contract_parameters => {
            subscribe      => 1,
            proposal_array => 1,
            date_start     => $now,
            barriers       => [
                map {
                    '' . $_
                } $pa->barriers->@*
            ],
            app_markup_percentage => '0',
            currency              => $pa->client->currency,
            base_commission       => '0.015',
            spot                  => '6474.13',
            staking_limits        => {
                max => 50000,
                min => '0.35'
            },
            duration           => '5d',
            spot_time          => $now,
            amount             => 10,
            amount_type        => 'stake',
            underlying         => $symbol,
            bet_types          => [$pa->contract_types->@*],
            deep_otm_threshold => '0.025'
        },
        rpc_time => '38.201'
    };
};

publish proposal_array => sub {
    my $pa           = $_->proposal_array;
    my $symbol       = $pa->underlying->symbol;
    my $display_name = $pa->underlying->display_name;
    my $lcn          = $pa->client->landing_company_name;
    my $real         = ($lcn =~ /virtual$/) ? 0 : 1;
    return {
        sprintf(
            'PRICER_KEYS::["amount","1000","barriers",[%s],"basis","payout","contract_type",[%s],"currency","%s","duration","%s","duration_unit","%s","landing_company","%s","price_daemon_cmd","price","proposal_array","1","real_money","%s","skips_price_validation","1","subscribe","1","symbol","%s"]',

            join(',', map { "\"$_\"" } $pa->barriers->@*),
            join(',', map { "\"$_\"" } $pa->contract_types->@*),
            $pa->client->currency,
            $pa->duration,
            $pa->duration_unit,
            $lcn, $real,
            $pa->underlying->symbol
            ) => {

            rpc_time  => 62.07,
            proposals => {
                map {
                    my $contract_type = $_;
                    $contract_type => [
                        map { {
                                display_value    => 10,
                                supplied_barrier => $_,
                                barrier          => $_,
                                theo_probability => rand,
                                ask_price        => 10,
                                longcode         => $pa->longcodes->{$contract_type}{$_}}
                        } $pa->barriers->@*
                        ]
                } $pa->contract_types->@*
            },
            price_daemon_cmd => 'price'
            },
    };
};

1;
