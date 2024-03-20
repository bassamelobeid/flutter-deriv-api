use BOM::Pricing::v3::Contract;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis    qw(initialize_realtime_ticks_db);
use Date::Utility;
use Postgres::FeedDB::Spot::Tick;
use Test::MockModule;
use Test::Most;
initialize_realtime_ticks_db();

my $now         = Date::Utility->new(time);
my $is_arrayref = sub {
    return 0, "not arrayref" unless ref shift eq 'ARRAY';
};

subtest 'prepare_ask' => sub {
    my $params = {
        "proposal"      => 1,
        "subscribe"     => 1,
        "amount"        => "2",
        "basis"         => "payout",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "symbol"        => "R_50",
        "duration"      => "2",
        "duration_unit" => "m"
    };
    my $expected = {
        'barrier'     => 'S0P',
        'subscribe'   => 1,
        'duration'    => '2m',
        'amount_type' => 'payout',
        'bet_type'    => 'CALL',
        'underlying'  => 'R_50',
        'currency'    => 'USD',
        'amount'      => '2',
        'proposal'    => 1,
        'date_start'  => 0,
    };
    cmp_deeply(BOM::Pricing::v3::Contract::prepare_ask($params), $expected, 'prepare_ask CALL ok');
    $params = {
        %$params,
        date_expiry => '2015-01-01',
        barrier     => 'S0P',
        barrier2    => 'S1P',
    };
    $expected = {
        %$expected,
        fixed_expiry  => 1,
        high_barrier  => 'S0P',
        low_barrier   => 'S1P',
        date_expiry   => '2015-01-01',
        duration_unit => 'm',
        duration      => '2',
    };
    delete $expected->{barrier};
    delete $expected->{barrier2};
    cmp_deeply(BOM::Pricing::v3::Contract::prepare_ask($params), $expected, 'result is ok after added date_expiry and barrier and barrier2');

    delete $params->{barrier};
    $expected->{barrier} = 'S0P';
    delete $expected->{high_barrier};
    delete $expected->{low_barrier};
    cmp_deeply(BOM::Pricing::v3::Contract::prepare_ask($params),
        $expected, 'will set barrier default value and delete barrier2 if contract type is not like ASIAN');

    delete $expected->{barrier};
    $expected->{barrier2} = 'S1P';
    for my $t (qw(ASIAN)) {
        $params->{contract_type} = $t;
        $expected->{bet_type}    = $t;
        cmp_deeply(BOM::Pricing::v3::Contract::prepare_ask($params), $expected, 'will not set barrier if contract type is like ASIAN ');
    }

    $params = {
        "proposal"      => 1,
        "subscribe"     => 1,
        "multiplier"    => "5",
        "contract_type" => "LBFLOATCALL",
        "currency"      => "USD",
        "symbol"        => "R_50",
        "duration"      => "15",
        "duration_unit" => "m",
    };
    $expected = {
        'subscribe'  => 1,
        'duration'   => '15m',
        'multiplier' => '5',
        'bet_type'   => 'LBFLOATCALL',
        'underlying' => 'R_50',
        'currency'   => 'USD',
        'proposal'   => 1,
        'date_start' => 0,
    };

    cmp_deeply(BOM::Pricing::v3::Contract::prepare_ask($params), $expected, 'prepare_ask LBFLOATCALL ok');

    $params = {
        "proposal"      => 1,
        "subscribe"     => 1,
        "basis"         => "payout",
        "payout"        => "10",
        "contract_type" => "RESETCALL",
        "currency"      => "USD",
        "symbol"        => "R_50",
        "duration"      => "15",
        "duration_unit" => "m",
        'barrier'       => 'S0P',
    };
    $expected = {
        'barrier'     => 'S0P',
        'subscribe'   => 1,
        'duration'    => '15m',
        'bet_type'    => 'RESETCALL',
        'underlying'  => 'R_50',
        'currency'    => 'USD',
        'proposal'    => 1,
        'date_start'  => 0,
        'amount_type' => 'payout',
        'payout'      => '10',
    };

    cmp_deeply(BOM::Pricing::v3::Contract::prepare_ask($params), $expected, 'prepare_ask RESETCALL ok');

    $params = {
        "proposal"      => 1,
        "subscribe"     => 1,
        "basis"         => "payout",
        "payout"        => "100",
        "contract_type" => "ONETOUCH",
        "currency"      => "USD",
        "symbol"        => "R_50",
        "duration"      => "5",
        "duration_unit" => "t",
        'barrier'       => '+0.3054',
    };
    $expected = {
        'barrier'     => '+0.3054',
        'subscribe'   => 1,
        'duration'    => '5t',
        'bet_type'    => 'ONETOUCH',
        'underlying'  => 'R_50',
        'currency'    => 'USD',
        'proposal'    => 1,
        'date_start'  => 0,
        'amount_type' => 'payout',
        'payout'      => '100',
    };

    cmp_deeply(BOM::Pricing::v3::Contract::prepare_ask($params), $expected, 'prepare_ask ONETOUCH ok');

};

subtest 'get_ask' => sub {
    my $params = {
        "proposal"         => 1,
        "amount"           => "100",
        "basis"            => "payout",
        "contract_type"    => "CALL",
        "currency"         => "USD",
        "duration"         => "60",
        "duration_unit"    => "s",
        "symbol"           => "R_50",
        "streaming_params" => {from_pricer => 1},
    };
    my $mock_contract = Test::MockModule->new('BOM::Product::Contract::Call');

    $mock_contract->mock('is_valid_to_buy', sub { return undef });

    my $result = BOM::Pricing::v3::Contract::_get_ask(BOM::Pricing::v3::Contract::prepare_ask($params));

    ok $result->{error}, 'ContractValidationError';
    $mock_contract->unmock('is_valid_to_buy');

    $result = BOM::Pricing::v3::Contract::_get_ask(BOM::Pricing::v3::Contract::prepare_ask($params));
    ok(delete $result->{spot_time},  'result have spot time');
    ok(delete $result->{date_start}, 'result have date_start');
    my $expected = {
        'display_value' => '51.19',
        'ask_price'     => '51.19',
        'longcode'      => [
            "Win payout if [_1] is strictly higher than [_4] at [_3] after [_2].",
            ["Volatility 50 Index"],
            ["contract start time"],
            {
                class => "Time::Duration::Concise::Localize",
                value => 60
            },
            ["entry spot"],
        ],
        'spot'             => '963.3054',
        'payout'           => '100',
        'theo_probability' => 0.499862430427529,
        'date_expiry'      => ignore(),
        'contract_details' => {
            'barrier' => '963.3054',
        },
        'contract_parameters' => {
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
            'date_start'            => ignore(),
            'staking_limits'        => {
                'min' => '0.35',
                'max' => 50000
            }}};
    cmp_deeply($result, $expected, 'the left values are all right');

    $params->{symbol} = "invalid symbol";
    $result = BOM::Pricing::v3::Contract::_get_ask(BOM::Pricing::v3::Contract::prepare_ask($params));
    is $result->{error}{code},                 'ContractCreationFailure',                'error code is ContractCreationFailure';
    is $result->{error}{message_to_client}[0], 'Trading is not offered for this asset.', 'correct message to client';

    cmp_deeply(
        BOM::Pricing::v3::Contract::_get_ask({}),
        {
            error => {
                message_to_client => ['Missing required contract parameters ([_1]).', 'bet_type'],
                code              => "ContractCreationFailure",
                details           => {field => 'contract_type'},
            }
        },
        'ContractCreationFailure with empty parameters'
    );
};

subtest 'send_ask date_expiry_smaller' => sub {
    my $params = {
        'proposal'         => 1,
        'fixed_expiry'     => 1,
        'date_expiry'      => 1476670200,
        'contract_type'    => 'PUT',
        'basis'            => 'payout',
        'currency'         => 'USD',
        'symbol'           => 'R_50',
        'amount'           => '100',
        'date_start'       => 1476676000,
        "streaming_params" => {from_pricer => 1},
    };
    my $result = BOM::Pricing::v3::Contract::send_ask({args => $params});
    is($result->{error}{code}, 'ContractCreationFailure', 'error code is ContractCreationFailure if start time is in the past');
    is(
        $result->{error}{message_to_client}[0],
        'Expiry time cannot be in the past.',
        'errors response is correct when date_expiry < date_start with payout_type is payout'
    );

    $params = {
        'proposal'         => 1,
        'fixed_expiry'     => 1,
        'date_expiry'      => '1476670200',
        'contract_type'    => 'PUT',
        'basis'            => 'stake',
        'currency'         => 'USD',
        'symbol'           => 'R_50',
        'amount'           => '11',
        'date_start'       => '1476670200',
        "streaming_params" => {from_pricer => 1},
    };
    $result = BOM::Pricing::v3::Contract::send_ask({args => $params});

    is($result->{error}{code}, 'ContractCreationFailure', 'error code is ContractCreationFailure if start time == expiry time');
    is(
        $result->{error}{message_to_client}[0],
        'Expiry time cannot be equal to start time.',
        'errors response is correct when date_expiry = date_start with payout_type is stake'
    );
};

subtest 'send_ask LBFLOATCALL' => sub {

    my $params = {
        "proposal"        => 1,
        "multiplier"      => "100",
        "contract_type"   => "LBFLOATCALL",
        "currency"        => "USD",
        "duration"        => "15",
        "duration_unit"   => "m",
        "symbol"          => "R_50",
        "landing_company" => "virtual",
        streaming_params  => {from_pricer => 1},
    };

    my $result = BOM::Pricing::v3::Contract::send_ask({args => $params});

    ok(delete $result->{spot_time},  'result have spot time');
    ok(delete $result->{date_start}, 'result have date_start');
    my $expected = {
        'display_value'    => '203.00',
        'ask_price'        => '203.00',
        'longcode'         => code($is_arrayref),
        'spot'             => '963.3054',
        'multiplier'       => 100,
        'payout'           => '0',
        'theo_price'       => '199.145854964839',
        'contract_details' => {
            'barrier' => '963.3054',
        },
        'date_expiry'         => ignore(),
        'rpc_time'            => ignore(),
        'contract_parameters' => ignore()};
    cmp_deeply($result, $expected, 'the left values are all right');

};

subtest 'send_ask RESETCALL' => sub {
    my $params = {
        "proposal"        => 1,
        "amount"          => "10",
        "basis"           => "payout",
        "contract_type"   => "RESETCALL",
        "currency"        => "USD",
        "duration"        => "15",
        "duration_unit"   => "m",
        "symbol"          => "R_50",
        "landing_company" => "svg",
        "barrier2"        => 1,
    };

    my $result = BOM::Pricing::v3::Contract::send_ask({args => $params});
    is $result->{error}{code}, 'BarrierValidationError', 'BarrierValidationError';

    delete $params->{barrier2};

    $result = BOM::Pricing::v3::Contract::send_ask({args => $params});
    diag explain $result->{error} if exists $result->{error};
    ok(delete $result->{spot_time},  'result have spot time');
    ok(delete $result->{date_start}, 'result have date_start');

    my $expected = {
        'display_value' => '6.37',
        'ask_price'     => '6.37',
        'longcode'      => [
            "Win payout if [_1] after [_3] is strictly higher than it was at either entry or [_5].",
            ["Volatility 50 Index"],
            ["contract start time"],
            {
                class => "Time::Duration::Concise::Localize",
                value => 900
            },
            ["entry spot"],
            {
                class => "Time::Duration::Concise::Localize",
                value => 450
            },
        ],

        'spot'             => '963.3054',
        'payout'           => '10',
        'skip_streaming'   => 1,
        'contract_details' => {
            'barrier' => '963.3054',
        },
        'rpc_time'            => ignore(),
        'date_expiry'         => ignore(),
        'contract_parameters' => ignore()};
    cmp_deeply($result, $expected, 'the left values are all right');
};

subtest 'send_ask EXPIRYRANGE' => sub {
    my $params = {
        "proposal"        => 1,
        "barrier"         => 963.3090,
        "barrier2"        => 963.3000,
        "contract_type"   => "EXPIRYRANGE",
        "currency"        => "USD",
        "duration"        => "15",
        "duration_unit"   => "m",
        'payout'          => '20',
        "symbol"          => "R_50",
        "landing_company" => "virtual",
        streaming_params  => {from_pricer => 1},
    };

    my $result = BOM::Pricing::v3::Contract::send_ask({args => $params});

    ok(delete $result->{spot_time},  'result have spot time');
    ok(delete $result->{date_start}, 'result have date_start');
    my $expected = {
        'display_value' => '0.50',
        'ask_price'     => '0.50',
        'longcode'      => [
            "Win payout if [_1] ends strictly between [_5] to [_4] at [_3] after [_2].",
            ["Volatility 50 Index"],
            ["contract start time"],
            {
                class => "Time::Duration::Concise::Localize",
                value => 900
            },
            "963.3090",
            "963.3000",
        ],
        'spot'             => '963.3054',
        'payout'           => '20',
        'theo_probability' => '0.00139540603914123',
        'contract_details' => {
            'high_barrier' => '963.3090',
            'low_barrier'  => '963.3000',
        },
        'date_expiry'         => ignore(),
        'rpc_time'            => ignore(),
        'contract_parameters' => ignore()};
    cmp_deeply($result, $expected, 'the left values are all right');

};

subtest 'send_ask ONETOUCH' => sub {
    my $params = {
        "proposal"        => 1,
        "amount"          => "100",
        "basis"           => "payout",
        "contract_type"   => "ONETOUCH",
        "currency"        => "USD",
        "duration"        => "5",
        "duration_unit"   => "t",
        "symbol"          => "R_50",
        "landing_company" => "malta",
        "barrier"         => "+0.3054"
    };

    my $result = BOM::Pricing::v3::Contract::send_ask({args => $params});

    is $result->{error}{code}, 'OfferingsValidationError', 'Trading is not offered for malta';

    $params->{landing_company} = 'svg';
    $result = BOM::Pricing::v3::Contract::send_ask({args => $params});
    diag explain $result->{error} if exists $result->{error};

    ok(delete $result->{spot_time},  'result have spot time');
    ok(delete $result->{date_start}, 'result have date_start');
    my $expected = {
        'display_value' => '19.76',
        'ask_price'     => '19.76',
        'longcode'      => [
            "Win payout if [_1] touches [_4] through [plural,_3,%d tick,%d ticks] after [_2].",
            ["Volatility 50 Index"], ["first tick"], [5], ["entry spot plus [_1]", 0.3054],
        ],
        'skip_streaming'   => 0,
        'spot'             => '963.3054',
        'payout'           => '100',
        'date_expiry'      => ignore(),
        'rpc_time'         => ignore(),
        'contract_details' => {
            'barrier' => '963.6108',
        },
        'contract_parameters' => {
            'deep_otm_threshold'    => '0.025',
            'barrier'               => '+0.3054',
            'duration'              => '5t',
            'bet_type'              => 'ONETOUCH',
            'underlying'            => 'R_50',
            'currency'              => 'USD',
            'base_commission'       => '0.032',
            'min_commission_amount' => '0.02',
            'amount'                => '100',
            'amount_type'           => 'payout',
            'app_markup_percentage' => 0,
            'proposal'              => 1,
            'date_start'            => ignore(),
            'landing_company'       => 'svg',
            'staking_limits'        => {
                'min' => '0.35',
                'max' => 50000
            }}};
    cmp_deeply($result, $expected, 'the left values are all right');
};

subtest 'send_ask MULTUP' => sub {
    my $params = {
        "proposal"      => 1,
        "amount"        => "100",
        "basis"         => "payout",
        "contract_type" => "MULTUP",
        "currency"      => "USD",
        "symbol"        => "R_100",
        "multiplier"    => 10,
        "duration_unit" => "m",
        "duration"      => 5,
    };

    my $expected = {
        'code'              => 'ContractCreationFailure',
        'details'           => {'field' => 'basis'},
        'message_to_client' => ['Basis must be [_1] for this contract.', 'stake'],
    };

    my $result = BOM::Pricing::v3::Contract::_get_ask(BOM::Pricing::v3::Contract::prepare_ask($params));
    cmp_deeply($result->{error}, $expected, 'ContractCreationFailure basis');

    $params->{basis} = 'stake';
    $result = BOM::Pricing::v3::Contract::send_ask({args => $params});

    $expected = {
        'code'              => 'ContractCreationFailure',
        'details'           => {'field' => 'duration'},
        'message_to_client' => ['Invalid input (duration or date_expiry) for this contract type ([_1]).', 'MULTUP'],
    };
    cmp_deeply($result->{error}, $expected, 'ContractCreationFailure duration');

    delete $params->{duration_unit};
    delete $params->{duration};
    my $mocked = Test::MockModule->new('Quant::Framework::Underlying');
    $mocked->mock('tick_at' => sub { return Postgres::FeedDB::Spot::Tick->new(quote => 100, epoch => Date::Utility->new->epoch) });

    $result = BOM::Pricing::v3::Contract::send_ask({args => $params});
    note explain $result if $result->{error};

    $expected = {
        'commission'       => '0.50',
        'contract_details' => {
            'minimum_stake' => '1.00',
            'maximum_stake' => '2000.00'
        },
        'date_expiry'         => ignore(),
        'date_start'          => ignore(),
        'multiplier'          => 10,
        'ask_price'           => '100.00',
        'longcode'            => code($is_arrayref),
        'skip_basis_override' => 1,
        'skip_streaming'      => 0,
        'spot'                => '65258.19',
        'spot_time'           => ignore(),
        'rpc_time'            => ignore(),
        'payout'              => 0,
        'display_value'       => '100.00',
        'contract_parameters' => ignore(),
        'limit_order'         => ignore(),
    };
    cmp_deeply($result, $expected, 'get_ask MULTUP right');
};

subtest 'send_ask ACCU' => sub {
    my $params = {
        "proposal"      => 1,
        "amount"        => "100",
        "basis"         => "payout",
        "contract_type" => "ACCU",
        "currency"      => "USD",
        "symbol"        => "1HZ100V",
    };

    my $expected = {
        'code'              => 'ContractCreationFailure',
        'details'           => {'field' => 'basis'},
        'message_to_client' => ['Basis must be [_1] for this contract.', 'stake'],
    };

    my $result = BOM::Pricing::v3::Contract::_get_ask(BOM::Pricing::v3::Contract::prepare_ask($params));
    cmp_deeply($result->{error}, $expected, 'ContractCreationFailure basis');

    $params->{basis} = 'stake';
    $result = BOM::Pricing::v3::Contract::send_ask({args => $params});

    $expected = {
        'code'              => 'ContractCreationFailure',
        'details'           => {'field' => 'growth_rate'},
        'message_to_client' => ['Missing required contract parameters ([_1]).', 'growth_rate'],
    };
    cmp_deeply($result->{error}, $expected, 'ContractCreationFailure growth_rate');

    $params->{growth_rate} = 0.03;
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, '1HZ100V']);

    my $mocked = Test::MockModule->new('Quant::Framework::Underlying');
    $mocked->mock('tick_at' => sub { return Postgres::FeedDB::Spot::Tick->new(quote => 100, epoch => Date::Utility->new->epoch) });

    $result = BOM::Pricing::v3::Contract::send_ask({args => $params});
    note explain $result if $result->{error};

    $expected = {
        'ask_price'        => '100.00',
        'contract_details' => {
            'barrier_spot_distance'        => '0.039',
            'high_barrier'                 => '100.039',
            'low_barrier'                  => '99.961',
            'maximum_payout'               => '10000',
            'maximum_stake'                => '2000.00',
            'maximum_ticks'                => '90',
            'minimum_stake'                => '1.00',
            'tick_size_barrier'            => '0.000386433279',
            'tick_size_barrier_percentage' => '0.03864%',
        },
        'contract_parameters' => ignore(),
        'date_expiry'         => ignore(),
        'date_start'          => ignore(),
        'display_value'       => '100.00',
        'longcode'            => code($is_arrayref),
        'payout'              => 0,
        'rpc_time'            => ignore(),
        'skip_basis_override' => 1,
        'skip_streaming'      => 0,
        'spot'                => '100.00',
        'spot_time'           => ignore(),
    };
    cmp_deeply($result, $expected, 'get_ask ACCU right');
};

done_testing;
