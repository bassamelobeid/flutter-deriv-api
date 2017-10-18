#!perl
use strict;
use warnings;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use Test::Warnings qw(warning warnings);
use Test::MockModule;
use Test::MockTime::HiRes;
use Date::Utility;

use Data::Dumper;
use Quant::Framework::Utils::Test;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Data::UUID;

use BOM::Pricing::v3::Contract;
use BOM::Platform::Context qw (request);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Platform::RedisReplicated;
use BOM::Product::ContractFactory qw( produce_contract );
use LandingCompany::Offerings qw(reinitialise_offerings);
use Quant::Framework;
use BOM::Platform::Chronicle;

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
initialize_realtime_ticks_db();
my $now   = Date::Utility->new('2005-09-21 06:46:00');
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

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::Pricing::RPC')->app->ua);
request(BOM::Platform::Context::Request->new(params => {}));

create_ticks([100, $now->epoch - 899, 'R_50']);
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_50',
});

subtest 'validate_symbol' => sub {
    is(BOM::Pricing::v3::Contract::_validate_symbol('R_50'), undef, "return undef if symbol is valid");
    cmp_deeply(
        BOM::Pricing::v3::Contract::_validate_symbol('invalid_symbol'),
        {
            'error' => {
                'message' => 'Symbol [_1] invalid',
                'code'    => 'InvalidSymbol',
                params    => [qw/ invalid_symbol /],
            }
        },
        'return error if symbol is invalid'
    );
};

# We dont write unit test. We fuck unit tests.
set_fixed_time(Date::Utility->new()->epoch);

subtest 'prepare_ask' => sub {
    my $params = {
        "proposal"      => 1,
        "subscribe"     => 1,
        "unit"          => "2",
        "contract_type" => "LBFIXEDCALL",
        "currency"      => "USD",
        "symbol"        => "R_50",
        "duration"      => "15",
        "duration_unit" => "m",
        'barrier'     => 'S0P',
    };
    my $expected = {
        'barrier'     => 'S0P',
        'subscribe'   => 1,
        'duration'    => '15m',
        'unit'        => '2',
        'bet_type'    => 'LBFIXEDCALL',
        'underlying'  => 'R_50',
        'currency'    => 'USD',
        'proposal'    => 1,
        'date_start'  => 0
    };

    cmp_deeply(BOM::Pricing::v3::Contract::prepare_ask($params), $expected, 'prepare_ask result ok');
    $params = {
        %$params,
        date_expiry => '2015-01-01',
        barrier     => 'S20P',
    };
    $expected = {
        %$expected,
        fixed_expiry  => 1,
        date_expiry   => '2015-01-01',
        duration_unit => 'm',
        duration      => '15',
        barrier       => 'S20P',
    };
    delete $expected->{barrier};
    #cmp_deeply(BOM::Pricing::v3::Contract::prepare_ask($params), $expected, 'result is ok after added date_expiry and barrier and barrier2');

    delete $params->{barrier};
    $expected->{barrier} = 'S0P';
    delete $expected->{high_barrier};
    delete $expected->{low_barrier};
    #cmp_deeply(BOM::Pricing::v3::Contract::prepare_ask($params),
    #    $expected, 'will set barrier default value and delete barrier2 if contract type is not like ASIAN');

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

    my $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    my @expected_keys = (qw(
            bid_price
            current_spot_time
            contract_id
            underlying
            is_expired
            is_valid_to_sell
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
            entry_tick
            entry_tick_time
            current_spot
            entry_spot
            barrier_count
            audit_details
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
    my $params = {landing_company => 'costarica'};

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
            'longcode'     => "Receive the difference of Volatility 50 Index's maximum value during the life of the option and entry spot plus 0.0020 at 50 seconds after contract start time.",
            'display_name' => 'Volatility 50 Index',
            'date_expiry'  => $now->epoch - 50,
            'barrier'      => 'S20P',
        },
        'result is ok'
    );

};

subtest 'get_ask' => sub {
    my $params = {
        "proposal"         => 1,
        "unit"             => "100",
        "contract_type"    => "LBFIXEDCALL",
        "currency"         => "USD",
        "duration"         => "15",
        "duration_unit"    => "m",
        "symbol"           => "R_50",
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
        'display_value'       => '205.47',
        'ask_price'           => '205.47',
        'longcode'            => 'Receive the difference of Volatility 50 Index\'s maximum value during the life of the option and entry spot at 15 minutes after contract start time.',
        'spot'                => '963.3054',
        'payout'              => '0',
        'contract_parameters' => {
            'deep_otm_threshold'    => '0.025',
            'barrier'               => 'S0P',
            'duration'              => '15m',
            'bet_type'              => 'LBFIXEDCALL',
            'underlying'            => 'R_50',
            'currency'              => 'USD',
            base_commission         => '0.015',
            'unit'                  => '100',
            'app_markup_percentage' => 0,
            'proposal'              => 1,
            'date_start'            => ignore(),
        }
    };

    cmp_deeply($result, $expected, 'the left values are all right');
};

subtest 'send_ask' => sub {
    my $params = {
        client_ip => '127.0.0.1',
        args      => {
            "proposal"         => 1,
            "unit"             => "100",
            "contract_type"    => "LBFIXEDCALL",
            "currency"         => "USD",
            "duration"         => "15",
            "duration_unit"    => "m",
            "symbol"           => "R_50",
        }};

    my $result = $c->call_ok('send_ask', $params)->has_no_error->result;
    my $expected_keys =
        [sort { $a cmp $b } (qw(longcode spot display_value ask_price spot_time date_start rpc_time payout contract_parameters))];
    cmp_deeply([sort keys %$result], $expected_keys, 'result keys is correct');
    is(
        $result->{longcode},
        'Receive the difference of Volatility 50 Index\'s maximum value during the life of the option and entry spot at 15 minutes after contract start time.',
        'long code  is correct'
    );
};

#ToDo: Later add app_markup test

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
        bet_type              => $args{bet_type} // 'LBFIXEDCALL',
        currency              => 'USD',
        current_tick          => $args{current_tick} // $tick,
        unit                  => 100,
        date_start            => $args{date_start} // $date_start,
        date_expiry           => $args{date_expiry} // $date_expiry,
        barrier               => $args{barrier} // 'S20P',
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
