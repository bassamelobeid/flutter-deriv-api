use Test::Most;
use Test::MockTime::HiRes qw(set_absolute_time);
use BOM::Pricing::v3::Contract;
use BOM::Product::ContractFactory;
use Test::MockModule;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase;
set_absolute_time('2021-10-21T00:00:00Z');
note "set time to: " . Date::Utility->new->date . " - " . Date::Utility->new->epoch;
initialize_realtime_ticks_db();

local $SIG{__WARN__} = sub {
    # capture the warn for test
    my $msg = shift;
};

my $params = {
    landing_company => 'svg',
    short_code      => "TEST",
    currency        => 'USD',
    contract_id     => 1,
    is_sold         => 0,
    country_code    => 'cr',
};

my $result = BOM::Pricing::v3::Contract::get_bid($params);
is $result->{error}->{code}, 'GetProposalFailure', 'Invalid contract';

$params->{short_code} = "TICKHIGH_R_50_100_1619506193_10t_1";
$result = BOM::Pricing::v3::Contract::get_bid($params);
is $result->{error}->{code}, 'GetProposalFailure', 'create contract error';

$params->{short_code} = "DIGITMATCH_R_10_18.18_0_5T_7_0";
$result = BOM::Pricing::v3::Contract::get_bid($params);
is $result->{bid_price}, '1.64', 'bid_price';
ok $result->{contract_id}, 'get_bid';

$result = BOM::Pricing::v3::Contract::send_bid($params);
ok $result->{rpc_time}, 'send_bid with rpc_time';

$params = {
    'app_markup_percentage' => 0,
    'barrier'               => 'S0P',
    'subscribe'             => 1,
    'duration'              => '15m',
    'bet_type'              => 'RESETCALL',
    'underlying'            => 'R_50',
    'currency'              => 'USD',
    'proposal'              => 1,
    'date_start'            => 0,
    'amount_type'           => 'payout',
    'payout'                => '10',
};
my $contract = BOM::Product::ContractFactory::produce_contract($params);
$params = {
    contract           => $contract,
    is_valid_to_sell   => 1,
    is_valid_to_cancel => 1,
    is_sold            => 1,
    sell_time          => 1634775100,
};
my $expected = {
    'barrier_count'              => 1,
    'bid_price'                  => '6.13',
    'contract_id'                => ignore(),
    'contract_type'              => 'RESETCALL',
    'currency'                   => 'USD',
    'current_spot'               => '963.3054',
    'current_spot_display_value' => '963.3054',
    'current_spot_time'          => ignore(),
    'date_expiry'                => ignore(),
    'date_settlement'            => ignore(),
    'date_start'                 => ignore(),
    'display_name'               => 'Volatility 50 Index',
    'expiry_time'                => ignore(),
    'is_expired'                 => 0,
    'is_forward_starting'        => 0,
    'is_intraday'                => 1,
    'is_path_dependent'          => 0,
    'is_settleable'              => 0,
    'is_valid_to_cancel'         => 1,
    'is_valid_to_sell'           => 1,
    'longcode'                   => [
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
    'payout'     => 10,
    'shortcode'  => ignore(),
    'status'     => 'sold',
    'underlying' => 'R_50'
};

$result = BOM::Pricing::v3::Contract::_build_bid_response($params);
cmp_deeply($result, $expected, 'build_bid_response matches');

my $now_tickhighlow = Date::Utility->new('21-Oct-2021');

$params = {
    bet_type      => 'TICKHIGH',
    underlying    => 'R_50',
    selected_tick => 5,
    date_start    => $now_tickhighlow,
    date_pricing  => $now_tickhighlow,
    duration      => '5t',
    currency      => 'USD',
    payout        => 10,
};

my $quote = 100.000;
for my $i (0 .. 4) {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_50',
        quote      => $quote,
        epoch      => $now_tickhighlow->epoch + $i,
    });
    $quote += 0.01;
}

$params->{date_pricing} = $now_tickhighlow->plus_time_interval('5s');
$contract = BOM::Product::ContractFactory::produce_contract($params);

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_50',
    epoch      => $now_tickhighlow->epoch + 5,
    quote      => 100.1,
});

$contract = BOM::Product::ContractFactory::produce_contract({%$params, selected_tick => 5});
$params   = {
    contract           => $contract,
    is_valid_to_sell   => 0,
    is_valid_to_cancel => 0,
    is_sold            => 1
};

$expected = {
    'barrier_count'              => 1,
    'bid_price'                  => '10.00',
    'contract_id'                => ignore(),
    'contract_type'              => 'TICKHIGH',
    'currency'                   => 'USD',
    'current_spot'               => '100.1',
    'current_spot_display_value' => '100.1000',
    'current_spot_time'          => ignore(),
    'date_expiry'                => ignore(),
    'date_settlement'            => ignore(),
    'date_start'                 => ignore(),
    'display_name'               => 'Volatility 50 Index',
    'expiry_time'                => ignore(),
    'is_expired'                 => 1,
    'is_forward_starting'        => 0,
    'is_intraday'                => 1,
    'is_path_dependent'          => 1,
    'is_settleable'              => 1,
    'is_valid_to_cancel'         => 0,
    'is_valid_to_sell'           => 0,
    'longcode'                   =>
        ['Win payout if tick [_5] of [_1] is the highest among all [_3] ticks.', ['Volatility 50 Index'], ['first tick'], ['5'], ['0.0001'], '5'],
    'payout'                   => 10,
    'shortcode'                => ignore(),
    'status'                   => 'sold',
    'underlying'               => 'R_50',
    'selected_tick'            => 5,
    'selected_spot'            => 100.1,
    'tick_count'               => 5,
    'audit_details'            => ignore(),
    'barrier'                  => ignore(),
    'entry_spot'               => ignore(),
    'entry_spot_display_value' => ignore(),
    'entry_tick'               => ignore(),
    'entry_tick_display_value' => ignore(),
    'entry_tick_time'          => ignore(),
    'exit_tick'                => ignore(),
    'exit_tick_display_value'  => ignore(),
    'exit_tick_time'           => ignore(),
    'tick_stream'              => ignore(),
    'validation_error'         => ignore(),
    'validation_error_code'    => ignore(),
    'sell_spot'                => '100.1',
    'sell_spot_display_value'  => '100.1000',
    'sell_spot_time'           => ignore()};

$result = BOM::Pricing::v3::Contract::_build_bid_response($params);
cmp_deeply($result, $expected, 'build_bid_response matches');

my $now       = Date::Utility->new(1634775000);
my $sell_time = Date::Utility->new(1634775100);
my $expiry    = Date::Utility->new(1634776000);

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    epoch      => $now->epoch,
    quote      => 65258.19,
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    epoch      => $sell_time->epoch - 1,
    quote      => 65350.19,
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    epoch      => $sell_time->epoch,
    quote      => 65221.23,
});

$params = {
    'multiplier'            => 10,
    'proposal'              => 1,
    'date_start'            => $now,
    'currency'              => 'USD',
    'bet_type'              => 'MULTUP',
    'amount'                => '100',
    'app_markup_percentage' => 0,
    'underlying'            => 'R_100',
    'amount_type'           => 'stake'
};
$contract = BOM::Product::ContractFactory::produce_contract($params);
$params   = {
    contract           => $contract,
    is_valid_to_sell   => 1,
    is_valid_to_cancel => 1,
};
$result = BOM::Pricing::v3::Contract::_build_bid_response($params);
ok !$result->{error}, 'build_bid_response for MULTUP';
is $result->{'underlying'},    'R_100',  'underlying R_100';
is $result->{'bid_price'},     '100.00', 'bid_price matches';
is $result->{'contract_type'}, 'MULTUP', 'contract_type MULTUP';

$params = {
    'proposal'              => 1,
    'date_start'            => $now,
    'currency'              => 'USD',
    'date_expiry'           => $expiry,
    'bet_type'              => 'VANILLALONGCALL',
    'amount'                => '100',
    'barrier'               => '67750.20',
    'app_markup_percentage' => 0,
    'underlying'            => 'R_100',
    'amount_type'           => 'stake',
    'skip_validation'       => 1,
    'sell_time'             => $sell_time->epoch,
    'sell_price'            => 253
};

$contract = BOM::Product::ContractFactory::produce_contract($params);

$params = {
    contract           => $contract,
    is_valid_to_sell   => 1,
    is_valid_to_cancel => 1,
    sell_time          => $sell_time->epoch,
};
$result = BOM::Pricing::v3::Contract::_build_bid_response($params);
is $result->{exit_tick_time}, $sell_time->epoch - 1, 'correct sell at market tick';

done_testing;
