#!perl
use strict;
use warnings;
use BOM::Test::RPC::QueueClient;
use Test::Most;
use Test::Mojo;
use Test::Warnings qw(warning warnings);
use Test::MockModule;
use Test::MockTime::HiRes qw(set_relative_time restore_time);
use Date::Utility;
use Data::Dumper;
use Quant::Framework::Utils::Test;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Data::UUID;

use BOM::Pricing::v3::Contract;
use BOM::Platform::Context qw (request);
use BOM::Test::Initializations;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw( produce_contract );
use Quant::Framework;
use BOM::Config::Chronicle;
use BOM::Config::Runtime;

BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
    '{"yyy": {"market": "forex", "barrier_category": "euro_atm", "commission": "0.05", "name": "test commission", "updated_on": "xxx date", "updated_by": "xxyy"}}'
);

my $now = Date::Utility->new('2005-09-21 06:46:00');
diag(Date::Utility->new->date);
set_relative_time($now->epoch);
diag(Date::Utility->new->date);

initialize_realtime_ticks_db();

my $landing_company = 'svg';

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD AUD CAD-AUD JPY JPY-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol        => 'R_50',
        recorded_date => $now
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw (frxAUDCAD frxUSDCAD frxAUDUSD frxUSDJPY);

my $c = BOM::Test::RPC::QueueClient->new();
request(BOM::Platform::Context::Request->new(params => {}));

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
        'date_start'  => 0
    };
    cmp_deeply(BOM::Pricing::v3::Contract::prepare_ask($params), $expected, 'prepare_ask result ok');
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
    my $result = BOM::Pricing::v3::Contract::_get_ask(BOM::Pricing::v3::Contract::prepare_ask($params));
    diag explain $result->{error} if exists $result->{error};
    ok(delete $result->{spot_time},  'result have spot time');
    ok(delete $result->{date_start}, 'result have date_start');
    my $expected = {
        'display_value'       => '51.19',
        'ask_price'           => '51.19',
        'longcode'            => 'Win payout if Volatility 50 Index is strictly higher than entry spot at 1 minute after contract start time.',
        'spot'                => '963.3054',
        'payout'              => '100',
        'theo_probability'    => 0.499862430427529,
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
    ok $result->{error}, 'error for invalid symbol';
    is $result->{error}{code},              'ContractCreationFailure',                'error code is ContractCreationFailure';
    is $result->{error}{message_to_client}, 'Trading is not offered for this asset.', 'correct message to client';

    cmp_deeply(
        BOM::Pricing::v3::Contract::_get_ask({}),
        {
            error => {
                message_to_client => 'Missing required contract parameters (bet_type).',
                code              => "ContractCreationFailure",
                details           => {field => 'contract_type'},
            }
        },
        'ContractCreationFailure with empty parameters'
    );
};

subtest 'get_ask_when_date_expiry_smaller_than_date_start' => sub {
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
    my $result = BOM::Pricing::v3::Contract::_get_ask(BOM::Pricing::v3::Contract::prepare_ask($params));
    is($result->{error}{code}, 'ContractCreationFailure', 'error code is ContractCreationFailure if start time is in the past');
    is(
        $result->{error}{message_to_client},
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
    $result = BOM::Pricing::v3::Contract::_get_ask(BOM::Pricing::v3::Contract::prepare_ask($params));

    is($result->{error}{code}, 'ContractCreationFailure', 'error code is ContractCreationFailure if start time == expiry time');
    is(
        $result->{error}{message_to_client},
        'Expiry time cannot be equal to start time.',
        'errors response is correct when date_expiry = date_start with payout_type is stake'
    );
};

subtest 'send_ask - invalid symbol' => sub {
    my $params = {
        client_ip => '127.0.0.1',
        args      => {
            "proposal"         => 1,
            "amount"           => "100",
            "basis"            => "payout",
            "contract_type"    => "CALL",
            "currency"         => "USD",
            "duration"         => "60",
            "duration_unit"    => "s",
            "symbol"           => "Invalid",
            "streaming_params" => {from_pricer => 1},
        }};

    my $result = $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')
        ->error_message_is('Trading is not offered for this asset.');
};

subtest 'send_ask' => sub {
    my $params = {
        client_ip => '127.0.0.1',
        args      => {
            "proposal"         => 1,
            "amount"           => "100",
            "basis"            => "payout",
            "contract_type"    => "CALL",
            "currency"         => "USD",
            "duration"         => "60",
            "duration_unit"    => "s",
            "symbol"           => "R_50",
            "streaming_params" => {from_pricer => 1},
        }};

    my $result = $c->call_ok('send_ask', $params)->has_no_error->result;
    my $expected_keys =
        [sort { $a cmp $b }
            (qw(longcode spot display_value ask_price spot_time date_start rpc_time payout contract_parameters stash auth_time theo_probability))];
    cmp_deeply([sort keys %$result], $expected_keys, 'result keys is correct');
    is(
        $result->{longcode},
        'Win payout if Volatility 50 Index is strictly higher than entry spot at 1 minute after contract start time.',
        'long code  is correct'
    );
    {
        cmp_deeply([
                warnings {
                    $c->call_ok('send_ask', {args => {symbol => 'R_50'}})->has_error->error_code_is('ContractCreationFailure')
                        ->error_message_is('Missing required contract parameters (bet_type).');
                }
            ],
            bag(re('Use of uninitialized value')),
            'missing bet_type when checking contract_type'
        );

        my $mock_contract = Test::MockModule->new('BOM::Pricing::v3::Contract');
        $mock_contract->mock('_get_ask', sub { die "mock _get_ask dying on purpose" });
        cmp_deeply([
                warnings {
                    $c->call_ok('send_ask', {args => {symbol => 'R_50'}})->has_error->error_code_is('pricing error')
                        ->error_message_is('Unable to price the contract.');
                }
            ],
            bag(re('mock _get_ask dying'), re('Use of uninitialized value')),
            'have expected warnings when _get_ask dies'
        );
    }
};

subtest 'send_ask_when_date_expiry_smaller_than_date_start' => sub {
    my $params = {
        client_ip => '127.0.0.1',
        args      => {
            'proposal'      => 1,
            'fixed_expiry'  => 1,
            'date_expiry'   => '1476670200',
            'contract_type' => 'PUT',
            'basis'         => 'payout',
            'currency'      => 'USD',
            'symbol'        => 'R_50',
            'amount'        => '100',
            'duration_unit' => 'm',
            'date_start'    => '1476676000',

            "streaming_params" => {from_pricer => 1},
        }};
    $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')->error_message_is('Expiry time cannot be in the past.');
};

subtest 'get_bid' => sub {

    # just one tick for missing market data
    create_ticks([100, $now->epoch - 899, 'R_50']);
    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch,
        underlying => 'R_50',
    });

    my $contract = _create_contract(
        current_tick  => $tick,
        date_start    => $now->epoch - 900,
        date_expiry   => $now->epoch - 500,
        purchase_date => $now->epoch - 901
    );
    my $params = {
        short_code      => $contract->shortcode,
        contract_id     => $contract->id,
        currency        => 'USD',
        is_sold         => 0,
        country_code    => 'cr',
        landing_company => $landing_company,
    };
    $c->call_ok('get_bid', $params)->has_error->error_code_is('GetProposalFailure')
        ->error_message_is(
        'There was a market data disruption during the contract period. For real-money accounts we will attempt to correct this and settle the contract properly, otherwise the contract will be cancelled and refunded. Virtual-money contracts will be cancelled and refunded.'
        );

    $contract = _create_contract();

    $params = {
        short_code      => $contract->shortcode,
        contract_id     => $contract->id,
        currency        => 'USD',
        is_sold         => 0,
        sell_price      => $contract->payout,
        country_code    => 'cr',
        landing_company => $landing_company,
    };
    my $result        = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    my @expected_keys = (qw(
            bid_price
            current_spot_time
            contract_id
            underlying
            is_expired
            is_valid_to_sell
            is_valid_to_cancel
            is_settleable
            is_forward_starting
            is_path_dependent
            is_intraday
            date_start
            date_expiry
            date_settlement
            currency
            longcode
            shortcode
            payout
            contract_type
            display_name
            barrier
            exit_tick_time
            exit_tick
            exit_tick_display_value
            entry_tick
            entry_tick_display_value
            entry_tick_time
            current_spot
            current_spot_display_value
            entry_spot
            entry_spot_display_value
            barrier_count
            status
            audit_details
            stash
            expiry_time
    ));
    cmp_bag([sort keys %{$result}], [sort @expected_keys]);
    is($result->{status}, 'open', 'get the right status');
    $contract = _create_contract();

    $params = {
        short_code      => $contract->shortcode,
        contract_id     => $contract->id,
        currency        => 'USD',
        is_sold         => 0,
        sell_price      => $contract->payout,
        country_code    => 'cr',
        landing_company => $landing_company,
    };

    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;

    cmp_bag([sort keys %{$result}], [sort @expected_keys], 'keys of result is correct');
    is($result->{status}, 'open', 'get the right status');
};

subtest 'get_bid_skip_barrier_validation' => sub {
    my ($contract, $params, $result);

    create_ticks([964, $now->epoch - 899, 'R_50'], [964, $now->epoch - 501, 'R_50'], [964, $now->epoch - 499, 'R_50']);

    $contract = _create_contract(
        date_expiry  => $now->epoch - 500,
        bet_type     => 'ONETOUCH',
        barrier      => 963.3055,
        date_pricing => $now->epoch,
        date_start   => $now->epoch - 900,
    );
    $params = {
        short_code      => $contract->shortcode,
        contract_id     => $contract->id,
        currency        => 'USD',
        is_sold         => 0,
        sell_price      => $contract->value,
        country_code    => 'cr',
        landing_company => $landing_company,
    };

    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    ok(!exists $result->{validation_error}, "No barrier validation error");

    $params->{validation_params} = {skip_barrier_validation => 1};
    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    ok(!exists $result->{validation_error}, "No barrier validation error")
        or diag "validatione error: " . ($result->{validation_error} // '<undef>');
    is($result->{status}, 'open', 'status is open');

    $params->{sell_time} = $now->epoch;
    $params->{is_sold}   = 1;
    $result              = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    is($result->{status}, 'sold', 'contract sold');
    $params->{is_expired} = 1;
    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    is($result->{status}, 'lost', 'contract lost');
    restore_time();
};

my $method = 'get_contract_details';
subtest $method => sub {
    my $params = {landing_company => $landing_company};

    cmp_deeply([
            warnings {
                $c->call_ok($method, $params)
                    ->has_error->error_message_is('Cannot create contract', 'will report error if no short_code and currency');
            }
        ],

        # We get several undef warnings too, but we'll ignore them for this test
        supersetof(re('get_contract_details produce_contract failed')),
        '... and had warning about failed produce_contract'
    );

    my $contract = _create_contract();
    $params->{short_code} = $contract->shortcode;
    $params->{currency}   = 'USD';
    $c->call_ok($method, $params)->has_no_error->result_is_deeply({
            'symbol'       => 'R_50',
            'longcode'     => "Win payout if Volatility 50 Index is strictly higher than entry spot at 50 seconds after contract start time.",
            'display_name' => 'Volatility 50 Index',
            'date_expiry'  => $now->epoch - 50,
            'barrier'      => 'S0P',
            'stash'        => {
                valid_source               => 1,
                source_bypass_verification => 0,
                app_markup_percentage      => 0
            }
        },
        'result is ok'
    );
    create_ticks([0.9935, $now->epoch - 899, 'frxAUDCAD'], [0.9938, $now->epoch - 501, 'frxAUDCAD'], [0.9939, $now->epoch - 499, 'frxAUDCAD']);

    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        quote      => 0.9935,
        epoch      => $now->epoch,
        underlying => 'frxAUDCAD',
    });

    $contract = _create_contract(
        underlying    => 'frxAUDCAD',
        current_tick  => $tick,
        date_start    => $now->epoch - 900,
        date_expiry   => $now->epoch - 500,
        purchase_date => $now->epoch - 901,
        date_pricing  => $now->epoch,
    );
    $params = {
        short_code      => $contract->shortcode,
        contract_id     => $contract->id,
        currency        => 'USD',
        country_code    => 'cr',
        landing_company => $landing_company,
    };
    my $res             = $c->call_ok('get_bid', $params)->result;
    my $expected_result = {
        'barrier'                  => '0.99350',
        'contract_id'              => 10,
        'currency'                 => 'USD',
        'bid_price'                => '147.26',
        'payout'                   => '147.26',
        'date_expiry'              => 1127287660,
        'date_settlement'          => 1127287660,
        'date_start'               => 1127287260,
        'entry_spot'               => '0.9935',
        'entry_spot_display_value' => '0.99350',
        'entry_tick'               => '0.9935',
        'entry_tick_display_value' => '0.99350',
        'entry_tick_time'          => 1127287261,
        'exit_tick'                => '0.9938',
        'exit_tick_display_value'  => '0.99380',
        'exit_tick_time'           => 1127287659,
        'longcode'                 => 'Win payout if AUD/CAD is strictly higher than entry spot at 6 minutes 40 seconds after contract start time.',
        'shortcode'                => 'CALL_FRXAUDCAD_147.26_1127287260_1127287660_S0P_0',
        'underlying'               => 'frxAUDCAD',
        is_valid_to_sell           => 1,
        'status'                   => 'open',
        expiry_time                => 1127287660,
    };

    foreach my $key (keys %$expected_result) {
        cmp_ok $res->{$key}, 'eq', $expected_result->{$key}, "$key are matching ";
    }
    done_testing();
};

done_testing();

sub create_ticks {
    my @ticks = @_;

    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables();
    for my $tick (@ticks) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            quote      => $tick->[0],
            epoch      => $tick->[1],
            underlying => $tick->[2],
        });

    }
    return;
}

sub _create_contract {
    my %args = @_;

    #postpone 10 minutes to avoid conflicts
    $now = $now->plus_time_interval('10m');
    my $tick;
    unless ($args{no_tick}) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $now->epoch - 99,
            underlying => 'R_50',
        });

        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $now->epoch - 52,
            underlying => 'R_50',
        });

        $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $now->epoch,
            underlying => 'R_50',
        });
    }

    my $symbol        = $args{underlying} ? $args{underlying} : 'R_50';
    my $date_start    = $now->epoch - 100;
    my $date_expiry   = $now->epoch - 50;
    my $underlying    = create_underlying($symbol);
    my $purchase_date = $now->epoch - 101;
    my $contract_data = {
        underlying            => $underlying,
        bet_type              => $args{bet_type} // 'CALL',
        currency              => 'USD',
        current_tick          => $args{current_tick} // $tick,
        stake                 => 100,
        date_start            => $args{date_start} // $date_start,
        date_expiry           => $args{date_expiry} // $date_expiry,
        barrier               => $args{barrier} // 'S0P',
        app_markup_percentage => $args{app_markup_percentage} // 0,

        # this is not what we want to test here.
        # setting it to false.
        uses_empirical_volatility => 0,
    };
    if ($args{date_pricing}) {
        $contract_data->{date_pricing} = $args{date_pricing};
    }

    if ($args{duration}) {
        $contract_data->{duration} = $args{duration};
    }

    return produce_contract($contract_data);
}
