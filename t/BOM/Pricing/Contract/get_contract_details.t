use Test::Most;
use BOM::Pricing::v3::Contract;
use Test::MockModule;

# use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
# initialize_realtime_ticks_db();
# Test::MockTime::set_absolute_time('2019-09-10T08:00:00Z');

local $SIG{__WARN__} = sub {
    # capture the warn for test
    my $msg = shift;
    # note $msg;
};
my $mock_contract = Test::MockModule->new('BOM::Pricing::v3::Contract');


my $params = {
    landing_company => 'svg',
    short_code      => "TICKHIGH_R_50_100_1619506193_5t_1",
    currency        => 'USD'
};

throws_ok { BOM::Pricing::v3::Contract::get_contract_details() } qr/missing landing_company/, 'missing landing_company';

my $result = BOM::Pricing::v3::Contract::get_contract_details($params);

my $expected = {
    'barrier'      => undef,
    'date_expiry'  => 1619506203,
    'display_name' => 'Volatility 50 Index',
    'longcode'     => 'Win payout if tick 1 of Volatility 50 Index is the highest among all 5 ticks.',
    'symbol'       => 'R_50'
};

cmp_deeply($result, $expected, 'get_contract_details');

$mock_contract->mock(
    'produce_contract',
    sub {
        die 'produce_contract';
    });

$result = BOM::Pricing::v3::Contract::get_contract_details($params);
my $error = {
    'error' => {
        'code'              => 'GetContractDetails',
        'message_to_client' => 'Cannot create contract'
    }};
cmp_deeply($result, $error, 'produce_contract failed');
$mock_contract->unmock('produce_contract');

my $contract_param = {
    "proposal"      => 1,
    "amount"        => "100",
    "basis"         => "stake",
    "contract_type" => "MULTUP",
    "currency"      => "USD",
    "symbol"        => "R_100",
    "multiplier"    => 10,
    "duration_unit" => "h",
    "duration"      => 5,
};

my $short_code = BOM::Pricing::v3::Utility::create_relative_shortcode($contract_param);
is $short_code, 'MULTUP_R_100_0_18000_S0P_0', 'create_relative_shortcode';
$params->{short_code} = $short_code;

$result   = BOM::Pricing::v3::Contract::get_contract_details($params);

cmp_deeply($result, $error, 'Cannot create contract MULTUP');

# note "our msg :  $msg ";
# note "result";

done_testing;
