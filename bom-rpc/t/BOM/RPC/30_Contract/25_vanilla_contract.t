#!perl
use strict;
use warnings;
use BOM::Test::RPC::QueueClient;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use Date::Utility;

use BOM::Pricing::v3::Contract;
use BOM::Platform::Context                       qw(request);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Product::ContractFactory                qw(produce_contract);

my $now             = Date::Utility->new;
my $landing_company = 'svg';

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [100, $now->epoch + 1, 'R_100']);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

my $c = BOM::Test::RPC::QueueClient->new();
request(BOM::Platform::Context::Request->new(params => {}));

subtest 'vanilla - send_ask' => sub {
    my $args = {
        "proposal"      => 1,
        "amount"        => 10,
        "basis"         => "payout",
        "contract_type" => "Vanillalongcall",
        "currency"      => "USD",
        "symbol"        => "R_100",
        "duration"      => 2,
        "duration_unit" => "m",
        "barrier"       => '+0.40',
    };
    my $params = {
        client_ip => '127.0.0.1',
        args      => $args,
    };

    $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')->error_message_is('Basis must be stake for this contract.');

    $args->{basis} = 'stake';
    delete $args->{duration};

    $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')
        ->error_message_is('Please specify either duration or date_expiry.');

    $args->{duration} = 5;

    my $expected = {
        'longcode'            => ignore(),
        'spot'                => '100.00',
        'date_start'          => ignore(),
        'date_expiry'         => ignore(),
        'contract_parameters' => {
            'min_commission_amount' => '0.02',
            'app_markup_percentage' => 0,
            'amount_type'           => 'stake',
            'currency'              => 'USD',
            'deep_otm_threshold'    => '0.025',
            'barrier'               => '+0.40',
            'date_start'            => 0,
            'proposal'              => 1,
            'amount'                => '10',
            'base_commission'       => '0.872563900995952',
            'underlying'            => 'R_100',
            'bet_type'              => 'Vanillalongcall',
            'landing_company'       => 'virtual',
            'duration'              => '5m',
        },
        "contract_details" => {
            "barrier" => '100.40',

        },
        'auth_time'     => ignore(),
        'display_value' => '10.00',
        'stash'         => {
            'market'                     => 'synthetic_index',
            'app_markup_percentage'      => '0',
            'valid_source'               => 1,
            'source_type'                => 'official',
            'source_bypass_verification' => 0

        },
        'spot_time'                   => ignore(),
        'payout'                      => '0',
        'barrier_choices'             => ignore(),
        'display_number_of_contracts' => '640.90014',
        'max_stake'                   => '15',
        'min_stake'                   => '0.4',
        'rpc_time'                    => ignore(),
        'ask_price'                   => '10.00',
        skip_streaming                => 0,
        subchannel                    => 'v1,USD,10,stake,0,0.025,0.872563900995952,0.02,,,,,EN',
        channel                       =>
            'PRICER_ARGS::["amount","10","barrier","+0.40","basis","stake","contract_type","Vanillalongcall","country_code",null,"currency","USD","duration","5","duration_unit","m","landing_company","virtual","price_daemon_cmd","price","proposal","1","skips_price_validation","1","symbol","R_100"]',
        subscription_channel =>
            'PRICER_ARGS::["amount","10","barrier","+0.40","basis","stake","contract_type","Vanillalongcall","country_code",null,"currency","USD","duration","5","duration_unit","m","landing_company","virtual","price_daemon_cmd","price","proposal","1","skips_price_validation","1","symbol","R_100"]::v1,USD,10,stake,0,0.025,0.872563900995952,0.02,,,,,EN'
    };

    my $redis_mock = Test::MockModule->new('RedisDB');
    $redis_mock->mock(
        'hget',
        sub {
            my ($self, @args) = @_;
            return '{"tick_epoch":"123123123"}';
        });

    my $res = $c->call_ok('send_ask', $params)->has_no_error->result;
    cmp_deeply($res, $expected, 'send_ask output as expected');

};

subtest 'vanilla - get_bid' => sub {
    my $contract = produce_contract({
        bet_type     => 'Vanillalongcall',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        duration     => '10h',
        currency     => 'USD',
        amount_type  => 'stake',
        amount       => 10,
        barrier      => '+0.40',
    });

    my $params = {
        short_code      => $contract->shortcode,
        contract_id     => $contract->id,
        currency        => 'USD',
        is_sold         => 0,
        country_code    => 'cr',
        landing_company => 'virtual',
    };

    my $expected = {
        'is_sold'         => 0,
        'entry_tick_time' => ignore(),
        'stash'           => {
            'app_markup_percentage'      => '0',
            'source_bypass_verification' => 0,
            'valid_source'               => 1,
            source_type                  => 'official',
        },
        'entry_tick'                  => 100,
        'date_settlement'             => ignore(),
        'underlying'                  => 'R_100',
        'contract_type'               => 'VANILLALONGCALL',
        'is_path_dependent'           => '0',
        'current_spot_time'           => ignore(),
        'date_expiry'                 => ignore(),
        'currency'                    => 'USD',
        'display_name'                => 'Volatility 100 Index',
        'is_settleable'               => 0,
        'is_intraday'                 => 1,
        'entry_tick_display_value'    => '100.00',
        'is_expired'                  => 0,
        'is_forward_starting'         => 0,
        'bid_price'                   => '9.44',
        'shortcode'                   => ignore(),
        'contract_id'                 => '500',
        'longcode'                    => ignore(),
        'is_valid_to_sell'            => 1,
        'is_valid_to_cancel'          => 0,
        'entry_spot'                  => 100,
        'entry_spot_display_value'    => '100.00',
        'current_spot'                => 100,
        'current_spot_display_value'  => '100.00',
        'date_start'                  => $now->epoch,
        'status'                      => 'open',
        'expiry_time'                 => ignore(),
        'barrier_count'               => 1,
        'display_number_of_contracts' => '8.37887',
        'barrier'                     => '100.40',
    };
    my $res = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    cmp_deeply($res, $expected, 'get_bid as expected');
};

done_testing();
