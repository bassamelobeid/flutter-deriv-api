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
use BOM::Config::RedisReplicated;
use BOM::Product::ContractFactory qw( produce_contract );
use Quant::Framework;
use BOM::Config::Chronicle;

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

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);
request(BOM::Platform::Context::Request->new(params => {}));

create_ticks([100, $now->epoch - 899, 'R_50']);
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_50',
});

set_fixed_time(Date::Utility->new()->epoch);

subtest 'prepare_ask' => sub {
    my $params = {
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
    my $expected = {
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

    cmp_deeply(BOM::Pricing::v3::Contract::prepare_ask($params), $expected, 'prepare_ask result ok');
    $params = {
        %$params,
        date_expiry => '2015-01-01',
    };
    $expected = {
        %$expected,
        fixed_expiry  => 1,
        date_expiry   => '2015-01-01',
        duration_unit => 't',
        duration      => '5',
        barrier       => 'S29054P',
    };
    delete $expected->{barrier};

    delete $params->{barrier};
    $expected->{barrier} = 'S0P';
    delete $expected->{high_barrier};
    delete $expected->{low_barrier};
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
            'longcode'     => "Win payout if Volatility 50 Index touches entry spot plus 2.9054 through 5 ticks after first tick.",
            'display_name' => 'Volatility 50 Index',
            'date_expiry'  => '1127285670',
            'barrier'      => 'S29054P',
            stash          => {
                valid_source               => 1,
                source_bypass_verification => 0,
                app_markup_percentage      => 0
            }
        },
        'result is ok'
    );

};

subtest 'get_ask' => sub {
    my $params = {
        "proposal"        => 1,
        "amount"          => "100",
        "basis"           => "payout",
        "contract_type"   => "ONETOUCH",
        "currency"        => "USD",
        "duration"        => "5",
        "duration_unit"   => "t",
        "symbol"          => "R_50",
        "landing_company" => "virtual",
        "barrier"         => "+0.3054"
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
        'display_value' => '20.06',
        'ask_price'     => '20.06',
        'longcode'      => "Win payout if Volatility 50 Index touches entry spot plus 0.3054 through 5 ticks after first tick.",

        'spot'                => '963.3054',
        'payout'              => '100',
        'contract_parameters' => {
            'deep_otm_threshold'    => '0.025',
            'barrier'               => '+0.3054',
            'duration'              => '5t',
            'bet_type'              => 'ONETOUCH',
            'underlying'            => 'R_50',
            'currency'              => 'USD',
            base_commission         => '0.035',
            'amount'                => '100',
            'amount_type'           => 'payout',
            'app_markup_percentage' => 0,
            'proposal'              => 1,
            'date_start'            => ignore(),
            'landing_company'       => 'virtual',
            'staking_limits'        => {
                'min' => '0.35',
                'max' => 50000
            }}};

    cmp_deeply($result, $expected, 'the left values are all right');
};

subtest 'send_ask' => sub {
    my $params = {
        client_ip => '127.0.0.1',
        args      => {
            "proposal"        => 1,
            "payout"          => "100",
            "basis"           => "payout",
            "contract_type"   => "ONETOUCH",
            "currency"        => "USD",
            "duration"        => "5",
            "duration_unit"   => "t",
            "symbol"          => "R_50",
            "landing_company" => "virtual",
            "barrier"         => "+0.3054"
        }};

    my $result = $c->call_ok('send_ask', $params)->has_no_error->result;
    my $expected_keys =
        [sort { $a cmp $b } (qw(longcode spot display_value ask_price spot_time date_start rpc_time payout contract_parameters stash))];
    cmp_deeply([sort keys %$result], $expected_keys, 'result keys is correct');
    is(
        $result->{longcode},
        'Win payout if Volatility 50 Index touches entry spot plus 0.3054 through 5 ticks after first tick.',
        'long code  is correct'
    );
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
        epoch      => $now->epoch - 2,
        underlying => 'R_50',
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 1,
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
        bet_type              => $args{bet_type} // 'ONETOUCH',
        currency              => 'USD',
        current_tick          => $args{current_tick} // $tick,
        payout                => 100,
        amount_type           => 'payout',
        date_start            => $args{date_start} // $date_start,
        duration              => '5t',
        barrier               => '+2.9054',
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
