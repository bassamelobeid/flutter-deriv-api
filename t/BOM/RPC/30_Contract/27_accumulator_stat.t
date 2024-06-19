use strict;
use warnings;

use BOM::Platform::Context                       qw(request);
use BOM::Product::ContractFactory                qw(produce_contract);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::RPC::QueueClient;
use Date::Utility;
use Test::MockModule;
use Test::Mojo;
use Test::Most;

my $now             = Date::Utility->new;
my $landing_company = 'svg';

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [100, $now->epoch + 1, 'R_100']);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol        => 'R_100',
        recorded_date => $now
    });

my $c = BOM::Test::RPC::QueueClient->new();
request(BOM::Platform::Context::Request->new(params => {}));

my @ticks_stayed_in = [2, 6, 5, 2, 5, 6, 35, 5, 13, 5, 23, 5, 7, 20];

my %mock_data = (
    'accumulator::stat_history::R_100::growth_rate_0.01' => @ticks_stayed_in,
    'lrange'                                             => @ticks_stayed_in,
    'hget'                                               => '{"high_barrier": "101","tick_epoch": "123123123","low_barrier": "99"}',
    'exec' => [@ticks_stayed_in, '{"high_barrier": "101","tick_epoch": "123123123","low_barrier": "99"}']);

subtest 'accumulator - tick stayed in' => sub {
    my $args = {
        "proposal"      => 1,
        "amount"        => 100,
        "basis"         => "stake",
        "contract_type" => "ACCU",
        "currency"      => "USD",
        "growth_rate"   => 0.01,
        "symbol"        => "R_100"
    };
    my $params = {
        client_ip => '127.0.0.1',
        args      => $args,
    };

    my $expected = {
        'ask_price'        => '100.00',
        'auth_time'        => ignore(),
        "contract_details" => {
            "barrier_spot_distance"        => 0.062,
            "high_barrier"                 => 100.062,
            "last_tick_epoch"              => 123123123,
            "low_barrier"                  => 99.938,
            "maximum_payout"               => ignore(),
            "maximum_stake"                => '2000.00',
            "maximum_ticks"                => ignore(),
            "minimum_stake"                => '1.00',
            "tick_size_barrier"            => num(0.0006, 0.0001),
            "tick_size_barrier_percentage" => re('0.06[0-9]+%'),
            "ticks_stayed_in"              => [2, 6, 5, 2, 5, 6, 35, 5, 13, 5, 23, 5, 7, 21],
        },
        'contract_parameters' => {
            'amount'                => '100',
            'amount_type'           => 'stake',
            'app_markup_percentage' => 0,
            'base_commission'       => '0',
            'bet_type'              => 'ACCU',
            'currency'              => 'USD',
            'date_start'            => 0,
            'deep_otm_threshold'    => '0.025',
            'growth_rate'           => 0.01,
            'landing_company'       => 'virtual',
            'min_commission_amount' => '0.02',
            'proposal'              => 1,
            'underlying'            => 'R_100',
        },
        'date_expiry'   => ignore(),
        'date_start'    => ignore(),
        'display_value' => '100.00',
        'longcode'      => ignore(),
        'stash'         => {
            'app_markup_percentage'      => '0',
            'market'                     => 'synthetic_index',
            'source_bypass_verification' => 0,
            'source_type'                => 'official',
            'valid_source'               => 1,
        },
        'spot'         => '100.00',
        'spot_time'    => ignore(),
        'payout'       => '0',
        'rpc_time'     => ignore(),
        skip_streaming => 0,
        channel        =>
            'PRICER_ARGS::["amount","100","basis","stake","contract_type","ACCU","country_code",null,"currency","USD","growth_rate","0.01","landing_company","virtual","price_daemon_cmd","price","proposal","1","skips_price_validation","1","symbol","R_100"]',
        subchannel           => 'v1,USD,100,stake,0,0.025,0,0.02,,,,,EN',
        subscription_channel =>
            'PRICER_ARGS::["amount","100","basis","stake","contract_type","ACCU","country_code",null,"currency","USD","growth_rate","0.01","landing_company","virtual","price_daemon_cmd","price","proposal","1","skips_price_validation","1","symbol","R_100"]::v1,USD,100,stake,0,0.025,0,0.02,,,,,EN'
    };

    my $redis_mock = Test::MockModule->new('RedisDB');
    $redis_mock->mock('execute', sub { my ($self, $key) = @_; return $mock_data{$key} });

    my $res = $c->call_ok('send_ask', $params)->has_no_error->result;
    cmp_deeply($res, $expected, 'send_ask output as expected');

    my $tick_2 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 2,
            quote      => 100,
        },
        1
    );

    %mock_data = (
        'accumulator::stat_history::R_100::growth_rate_0.01' => @ticks_stayed_in,
        'lrange'                                             => @ticks_stayed_in,
        'hget'                                               => '{"high_barrier": "100","tick_epoch": "123123123","low_barrier": "99"}',
        'exec' => [@ticks_stayed_in, '{"high_barrier": "100","tick_epoch": "123123123","low_barrier": "99"}']);

    $redis_mock->mock('execute', sub { my ($self, $key) = @_; return $mock_data{$key} });

    $expected = {
        'ask_price'        => '100.00',
        'auth_time'        => ignore(),
        "contract_details" => {
            "barrier_spot_distance"        => 0.062,
            "high_barrier"                 => 100.062,
            "last_tick_epoch"              => 123123123,
            "low_barrier"                  => 99.938,
            "maximum_payout"               => ignore(),
            "maximum_stake"                => '2000.00',
            "maximum_ticks"                => ignore(),
            "minimum_stake"                => '1.00',
            "tick_size_barrier"            => num(0.0006, 0.0001),
            "tick_size_barrier_percentage" => re('0.06[0-9]+%'),
            "ticks_stayed_in"              => [2, 6, 5, 2, 5, 6, 35, 5, 13, 5, 23, 5, 7, 21, 0],

        },
        'contract_parameters' => {
            'amount'                => '100',
            'amount_type'           => 'stake',
            'app_markup_percentage' => 0,
            'base_commission'       => '0',
            'bet_type'              => 'ACCU',
            'currency'              => 'USD',
            'date_start'            => 0,
            'deep_otm_threshold'    => '0.025',
            'growth_rate'           => 0.01,
            'landing_company'       => 'virtual',
            'min_commission_amount' => '0.02',
            'proposal'              => 1,
            'underlying'            => 'R_100',
        },
        'date_expiry'   => ignore(),
        'date_start'    => ignore(),
        'display_value' => '100.00',
        'longcode'      => ignore(),
        'stash'         => {
            'app_markup_percentage'      => '0',
            'market'                     => 'synthetic_index',
            'source_bypass_verification' => 0,
            'source_type'                => 'official',
            'valid_source'               => 1,
        },
        'spot'         => '100.00',
        'spot_time'    => ignore(),
        'payout'       => '0',
        'rpc_time'     => ignore(),
        skip_streaming => 0,
        channel        =>
            'PRICER_ARGS::["amount","100","basis","stake","contract_type","ACCU","country_code",null,"currency","USD","growth_rate","0.01","landing_company","virtual","price_daemon_cmd","price","proposal","1","skips_price_validation","1","symbol","R_100"]',
        subchannel           => 'v1,USD,100,stake,0,0.025,0,0.02,,,,,EN',
        subscription_channel =>
            'PRICER_ARGS::["amount","100","basis","stake","contract_type","ACCU","country_code",null,"currency","USD","growth_rate","0.01","landing_company","virtual","price_daemon_cmd","price","proposal","1","skips_price_validation","1","symbol","R_100"]::v1,USD,100,stake,0,0.025,0,0.02,,,,,EN'
    };

    $res = $c->call_ok('send_ask', $params)->has_no_error->result;
    cmp_deeply($res, $expected, 'send_ask output as expected');
    $redis_mock->unmock_all();

};

done_testing();

