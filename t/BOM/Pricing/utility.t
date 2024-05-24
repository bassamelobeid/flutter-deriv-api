use Test::Most;
use BOM::Pricing::v3::Utility;
use BOM::Test::Initializations;

subtest 'update_price_metrics' => sub {

    my $redis_pricer = BOM::Config::Redis::redis_pricer;
    BOM::Pricing::v3::Utility::update_price_metrics('testkey', 0.1);

    is $redis_pricer->hget('PRICE_METRICS::COUNT',  'testkey'), 1,   'PRICE_METRICS::COUNT';
    is $redis_pricer->hget('PRICE_METRICS::TIMING', 'testkey'), 0.1, 'PRICE_METRICS::TIMING';
};

subtest 'non_binary_price_adjustment' => sub {

    my $response = {
        'display_value' => '51.19',
        'ask_price'     => '51.19',
        'spot'          => '963.3054',
        'payout'        => '100',
        'theo_price'    => 50,
    };

    my $contract_parameters = {
        'barrier'               => 'S0P',
        'duration'              => '60s',
        'bet_type'              => 'CALL',
        'amount_type'           => 'payout',
        'underlying'            => 'R_50',
        'currency'              => 'USD',
        'base_commission'       => '0.012',
        'maximum_ask_price'     => 1000,
        'amount'                => '100',
        'app_markup_percentage' => 60,
        'proposal'              => 1,
        'multiplier'            => 5
    };

    my $result   = BOM::Pricing::v3::Utility::non_binary_price_adjustment($contract_parameters, $response);
    my $expected = {
        'ask_price'     => '201.19',
        'display_value' => '201.19',
        'payout'        => '100',
        'spot'          => '963.3054'
    };
    cmp_deeply($result, $expected, 'response matches');

};

subtest 'binary_price_adjustment' => sub {

    my $response = {
        'display_value'    => '51.19',
        'ask_price'        => '51.19',
        'spot'             => '963.3054',
        'theo_probability' => 0.499862430427529,
    };

    my $contract_parameters = {
        'deep_otm_threshold'    => '0.025',
        'barrier'               => 'S0P',
        'duration'              => '60s',
        'bet_type'              => 'CALL',
        'amount_type'           => 'payout',
        'underlying'            => 'R_50',
        'currency'              => 'USD',
        'base_commission'       => '0.012',
        'min_commission_amount' => 0.02,
        'amount'                => '100',
        'app_markup_percentage' => 0,
        'proposal'              => 1,
        'staking_limits'        => {
            'min' => '0.35',
            'max' => '50'
        }};

    my $result = BOM::Pricing::v3::Utility::binary_price_adjustment($contract_parameters, $response);
    is $result->{error}->{code}, 'payout_outside_range', 'payout_outside_range error';

    $contract_parameters->{staking_limits}->{max} = '5000';
    $result = BOM::Pricing::v3::Utility::binary_price_adjustment($contract_parameters, $response);
    my $expected = {
        'ask_price'     => '2.50',
        'display_value' => '2.50',
        'payout'        => '100',
        'spot'          => '963.3054'
    };
    cmp_deeply($result, $expected, 'response matches');
};

subtest 'get_poc_parameters' => sub {
    my $lc     = 'testlc';
    my $result = BOM::Pricing::v3::Utility::get_poc_parameters(1, $lc);
    cmp_deeply($result, {}, 'empty results');

    my $params_key = join '::', ('POC_PARAMETERS', 1, $lc);
    BOM::Config::Redis::redis_pricer_shared_write->set($params_key, '["test","1"]');
    $result = BOM::Pricing::v3::Utility::get_poc_parameters(1, $lc);
    cmp_deeply($result, {test => 1}, 'poc_parameters matches');
};

subtest 'localize bid response' => sub {
    my $input = {
        display_name => ['display name [_1]', 'localized'],
        error        => {
            message_to_client => ['error [_1]', 'localized'],
        },
        limit_order => {
            take_profit => {
                display_name => 'Take profit',
            },
            another_limit => {
                display_name => ['limits [_1]', 'localized'],
            },
        },
        validation_error => ['validation error [_1]', 'localized'],
        audit_details    => {
            test => [{
                    name => ['msg1 [_1] [_2]', 'msg2', ['msg3']],
                    foo  => 7,
                }
            ],
        },
    };
    my $expect = {
        display_name => 'display name localized',
        error        => {
            message_to_client => 'error localized',
        },
        limit_order => {
            take_profit => {
                display_name => 'Take profit',
            },
            another_limit => {
                display_name => 'limits localized',
            },
        },
        validation_error => 'validation error localized',
        audit_details    => {
            test => [{
                    name => 'msg1 msg2 msg3',
                    foo  => 7,
                }
            ],
        },
    };
    BOM::Pricing::v3::Utility::localize_bid_response($input);
    cmp_deeply($input, $expect, 'bid response was localized');
};

subtest 'localize proposal response' => sub {
    my $input = {
        longcode    => ['longcode [_1]', 'localized'],
        limit_order => {
            take_profit => {
                display_name => 'Take profit',
            },
            another_limit => {
                display_name => ['limits [_1]', 'localized'],
            },
        },
    };
    my $expect = {
        longcode    => 'longcode localized',
        limit_order => {
            take_profit => {
                display_name => 'Take profit',
            },
            another_limit => {
                display_name => 'limits localized',
            },
        },
    };
    BOM::Pricing::v3::Utility::localize_proposal_response($input);
    cmp_deeply($input, $expect, 'proposal response was localized');
};

done_testing;
