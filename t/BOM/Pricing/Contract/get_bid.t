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
    'longcode'   => 'Win payout if Volatility 50 Index after 15 minutes is strictly higher than it was at either entry or 7 minutes 30 seconds.',
    'payout'     => 10,
    'shortcode'  => ignore(),
    'status'     => 'sold',
    'underlying' => 'R_50'
};
$result = BOM::Pricing::v3::Contract::_build_bid_response($params);
cmp_deeply($result, $expected, 'build_bid_response matches');

$params = {
    'multiplier'            => 10,
    'proposal'              => 1,
    'date_start'            => 0,
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

$params = {
    'proposal'              => 1,
    'date_start'            => $now,
    'currency'              => 'USD',
    'date_expiry'           => $expiry,
    'bet_type'              => 'TURBOSLONG',
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
