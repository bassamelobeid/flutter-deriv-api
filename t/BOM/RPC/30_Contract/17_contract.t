#!perl
use strict;
use warnings;
use Test::Most;
use Test::Warnings        qw(warnings);
use Test::MockTime::HiRes qw(set_relative_time);
use Date::Utility;

use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

use BOM::Pricing::v3::Contract;
use BOM::Platform::Context        qw (request);
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::MarketData               qw(create_underlying);
use BOM::Test::RPC::QueueClient;

my $now = Date::Utility->new('2005-09-21 06:46:00');
set_relative_time($now->epoch);
initialize_realtime_ticks_db();
my $email = 'test@binary.com';

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
    }) for qw(USD AUD CAD-AUD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => Date::Utility->new
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw (frxAUDCAD frxUSDCAD frxAUDUSD);

my $c = BOM::Test::RPC::QueueClient->new();
request(BOM::Platform::Context::Request->new(params => {}));

create_ticks([100, $now->epoch - 899, 'R_50']);
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_50',
});

subtest 'prepare_ask' => sub {
    my $params = {
        "proposal"      => 1,
        "subscribe"     => 1,
        "multiplier"    => "5",
        "contract_type" => "LBFLOATCALL",
        "currency"      => "USD",
        "symbol"        => "R_50",
        "duration"      => "15",
        "duration_unit" => "m",
    };
    my $expected = {
        'subscribe'  => 1,
        'duration'   => '15m',
        'multiplier' => '5',
        'bet_type'   => 'LBFLOATCALL',
        'underlying' => 'R_50',
        'currency'   => 'USD',
        'proposal'   => 1,
        'date_start' => 0,
    };

    cmp_deeply(BOM::Pricing::v3::Contract::prepare_ask($params), $expected, 'prepare_ask result ok');
    $params = {
        %$params,
        date_expiry => '2015-01-01',
    };
    $expected = {
        %$expected,
        fixed_expiry  => 1,
        date_expiry   => '2015-01-01',
        duration_unit => 'm',
        duration      => '15',
    };
    delete $expected->{barrier};

    delete $params->{barrier};
    $expected->{barrier} = 'S0P';
    delete $expected->{high_barrier};
    delete $expected->{low_barrier};
};

subtest 'send_ask for non-binary' => sub {
    note 'callputspread and multiplier are non-binary options';
    my $params = {
        client_ip => '127.0.0.1',
        args      => {
            "proposal"      => 1,
            "amount"        => 100,
            "barrier_range" => "tight",
            "basis"         => "payout",
            "contract_type" => "CALLSPREAD",
            "currency"      => "USD",
            "duration"      => 60,
            "duration_unit" => "s",
            "symbol"        => "R_100"
        }};

    my $result = $c->call_ok('send_ask', $params)->has_no_system_error->has_no_error->result;

    $params = {
        client_ip => '127.0.0.1',
        args      => {
            "proposal"      => 1,
            "amount"        => "100",
            "basis"         => "stake",
            "contract_type" => "MULTUP",
            "currency"      => "USD",
            "symbol"        => "R_100",
            "multiplier"    => 10

        }};
    # mocking tick_at as the relative time is now year 2058
    my $mocked = Test::MockModule->new('Quant::Framework::Underlying');
    $mocked->mock('tick_at' => sub { return Postgres::FeedDB::Spot::Tick->new(quote => 100, epoch => $now->epoch) });
    $result = $c->call_ok('send_ask', $params)->has_no_system_error->has_no_error->result;
};

subtest 'get_bid' => sub {

    my $contract = _create_contract(
        current_tick  => $tick,
        date_start    => $now->epoch - 900,
        date_expiry   => $now->epoch - 500,
        purchase_date => $now->epoch - 901
    );
    my $params = {
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => 'USD',
        is_sold     => 0,
    };
    $c->call_ok('get_bid', $params)->has_error->error_code_is('GetProposalFailure')
        ->error_message_is(
        'There was a market data disruption during the contract period. For real-money accounts we will attempt to correct this and settle the contract properly, otherwise the contract will be cancelled and refunded. Virtual-money contracts will be cancelled and refunded.'
        );

    $contract = _create_contract();

    $params = {
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => 'USD',
        is_sold     => 0,
    };
    my $result        = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    my @expected_keys = (qw(
            is_sold
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
            audit_details
            status
            multiplier
            stash
            expiry_time
    ));
    cmp_bag([sort keys %{$result}], [sort @expected_keys]);

    $contract = _create_contract();

    $params = {
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => 'USD',
        is_sold     => 0,
    };
    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;

    cmp_bag([sort keys %{$result}], [sort @expected_keys], 'keys of result is correct');

};

my $method = 'get_contract_details';
subtest $method => sub {
    my $params = {landing_company => 'svg'};

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

    my $decimate_cache = BOM::Market::DataDecimate->new({market => 'synthetic_index'});

    $decimate_cache->data_cache_back_populate_raw(
        'R_50',
        [{
                'symbol' => 'R_50',
                'epoch'  => 1127287461,
                'quote'  => '76.8996'
            },
            {
                'symbol' => 'R_50',
                'epoch'  => 1127287463,
                'quote'  => '76.8996'
            },
            {
                'symbol' => 'R_50',
                'epoch'  => 1127287510,
                'quote'  => '76.8996'
            }]);

    my $contract = _create_contract();
    $params->{short_code} = $contract->shortcode;
    $params->{currency}   = 'USD';
    $c->call_ok($method, $params)->has_no_error->result_is_deeply({
            'symbol'       => 'R_50',
            'longcode'     => "Win USD 100.00 times Volatility 50 Index's close minus low over the next 50 seconds.",
            'display_name' => 'Volatility 50 Index',
            'date_expiry'  => $now->epoch - 50,
            'barrier'      => '76.8996',
            stash          => {
                valid_source               => 1,
                source_bypass_verification => 0,
                app_markup_percentage      => 0,
                source_type                => 'official',
            },
        },
        'result is ok'
    );

};

subtest 'get_ask' => sub {
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

    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => time,
        underlying => 'R_50',
    });

    my $result = BOM::Pricing::v3::Contract::_get_ask(BOM::Pricing::v3::Contract::prepare_ask($params));

    diag explain $result->{error} if exists $result->{error};
    ok(delete $result->{spot_time},  'result have spot time');
    ok(delete $result->{date_start}, 'result have date_start');
    my $expected = {
        'display_value'       => '203.00',
        'ask_price'           => '203.00',
        'longcode'            => "Win USD 100.00 times Volatility 50 Index's close minus low over the next 15 minutes.",
        'spot'                => '963.3054',
        multiplier            => 100,
        'payout'              => '0',
        'theo_price'          => '199.145854964839',
        'date_expiry'         => ignore(),
        'contract_parameters' => {
            'deep_otm_threshold'    => '0.025',
            'duration'              => '15m',
            'bet_type'              => 'LBFLOATCALL',
            'underlying'            => 'R_50',
            'currency'              => 'USD',
            'base_commission'       => '0.02',
            'min_commission_amount' => '0.02',
            'multiplier'            => '100',
            'app_markup_percentage' => 0,
            'proposal'              => 1,
            'date_start'            => ignore(),
            'landing_company'       => 'virtual'
        }};
    cmp_deeply($result, $expected, 'the left values are all right');
};

subtest 'send_ask' => sub {
    my $params = {
        client_ip => '127.0.0.1',
        args      => {
            "proposal"        => 1,
            "multiplier"      => "100",
            "contract_type"   => "LBFLOATCALL",
            "currency"        => "USD",
            "duration"        => "15",
            "duration_unit"   => "m",
            "symbol"          => "R_50",
            "landing_company" => "virtual",
        }};

    my $result        = $c->call_ok('send_ask', $params)->has_no_error->result;
    my $expected_keys = [
        sort { $a cmp $b } (
            qw(longcode spot display_value multiplier ask_price spot_time date_expiry date_start rpc_time payout contract_parameters stash auth_time skip_streaming channel subchannel subscription_channel)
        )];
    cmp_deeply([sort keys %$result], $expected_keys, 'result keys is correct');
    is($result->{longcode}, 'Win USD 100.00 times Volatility 50 Index\'s close minus low over the next 15 minutes.', 'long code  is correct');
};

done_testing();

sub create_ticks {
    my @ticks = @_;

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
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 99,
        underlying => 'R_50',
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 52,
        underlying => 'R_50',
    });

    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch,
        underlying => 'R_50',
    });

    my $symbol        = $args{underlying} ? $args{underlying} : 'R_50';
    my $date_start    = $now->epoch - 100;
    my $date_expiry   = $now->epoch - 50;
    my $underlying    = create_underlying($symbol);
    my $purchase_date = $now->epoch - 101;
    my $contract_data = {
        underlying            => $underlying,
        bet_type              => $args{bet_type} // 'LBFLOATCALL',
        currency              => 'USD',
        current_tick          => $args{current_tick} // $tick,
        multiplier            => 100,
        date_start            => $args{date_start}            // $date_start,
        date_expiry           => $args{date_expiry}           // $date_expiry,
        app_markup_percentage => $args{app_markup_percentage} // 0,

        # this is not what we want to test here.
        # setting it to false.
        uses_empirical_volatility => 0,
    };
    if ($args{date_pricing}) {
        $contract_data->{date_pricing} = $args{date_pricing};
    }

    return produce_contract($contract_data);
}
