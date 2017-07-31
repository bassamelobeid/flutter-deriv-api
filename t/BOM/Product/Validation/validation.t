use strict;
use warnings;

use Time::HiRes;
use Test::MockTime qw/:all/;
use Test::Most qw(-Test::Deep);
use Test::Warnings;
use Test::Warnings qw/warning/;
use DateTime;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use LandingCompany::Offerings qw(reinitialise_offerings);
use Date::Utility;
use Postgres::FeedDB::Spot::Tick;

use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Platform::Runtime;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Platform::Chronicle;
use Quant::Framework;

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
initialize_realtime_ticks_db();

my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader);
my $mocked_decimate  = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked_decimate->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + rand(0.1)} } (0 .. 80)];
    });
my $mocked = Test::MockModule->new('BOM::Product::Contract');
$mocked->mock('market_is_inefficient', sub { 0 });
my $oft_used_date   = Date::Utility->new('2013-03-29 15:00:34');
my $an_hour_earlier = Date::Utility->new($oft_used_date->epoch - 3600);
my $that_morning    = Date::Utility->new('2013-03-29 08:43:00');

my $tick_params = {
    symbol => 'not_checked',
    epoch  => $oft_used_date->epoch,
    quote  => 100
};

my $tick = Postgres::FeedDB::Spot::Tick->new($tick_params);

#create an empty un-used even so ask_price won't fail preparing market data for pricing engine
#Because the code to prepare market data is called for all pricings in Contract
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }], recorded_date => Date::Utility->new('2013-03-27')});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'holiday',
    {
        recorded_date => Date::Utility->new('2013-03-27'),
        calendar      => {
            "25-Dec-12" => {
                "Christmas Day" => ['FSE'],
            },
            "26-Dec-12" => {
                "Christmas Holiday" => ['FSE'],
            },
            "31-Dec-12" => {
                " New Year's Eve" => ['FSE'],
            },
            "1-Jan-13" => {
                "New Year" => ['FSE'],
            },
            "29-Mar-13" => {
                "Good Friday" => ['FSE'],
            },
            "1-Apr-13" => {
                "Easter Monday" => ['FSE'],
            },
        },
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $an_hour_earlier,
    }) for (qw/USD EUR AUD SGD GBP AUD-USD EUR-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $an_hour_earlier->minus_time_interval('150d'),
    }) for (qw/USD EUR AUD SGD GBP AUD-USD EUR-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxAUDUSD',
        recorded_date => $an_hour_earlier,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol        => 'RDBULL',
        recorded_date => $an_hour_earlier->minus_time_interval('3d'),
        date          => Date::Utility->new
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol        => 'R_100',
        recorded_date => $an_hour_earlier->minus_time_interval('3d'),
        date          => Date::Utility->new
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxEURUSD',
        recorded_date => $that_morning->minus_time_interval('5d'),
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxEURUSD',
        recorded_date => $that_morning,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'GDAXI',
        recorded_date => $that_morning->minus_time_interval('5d'),
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'GDAXI',
        date          => Date::Utility->new,
        recorded_date => $an_hour_earlier
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol         => 'GDAXI',
        recorded_date  => $an_hour_earlier,
        spot_reference => $tick->quote,
    });

my $orig_suspended = BOM::Platform::Runtime->instance->app_config->quants->features->suspend_contract_types;
ok(BOM::Platform::Runtime->instance->app_config->quants->features->suspend_contract_types(['RANGE']), 'Suspended RANGE bet purchases!');
reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

subtest 'valid bet passing and stuff' => sub {

    my $underlying = create_underlying('frxAUDUSD');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '3d',
        barrier      => 'S0P',
        current_tick => $tick,
    };

    my $bet = produce_contract($bet_params);

    ok($bet->is_valid_to_buy, 'Valid for purchase');
    # If we look at it a few minutes later..
    $bet_params->{date_pricing} = $starting + 300;
    $bet_params->{current_tick} = Postgres::FeedDB::Spot::Tick->new({
        symbol => $bet->underlying->symbol,
        epoch  => $starting + 300,
        quote  => $bet->current_spot + 2 * $bet->underlying->pip_size
    });

    $bet_params = {
        underlying                 => $underlying,
        bet_type                   => 'CALL',
        currency                   => 'USD',
        payout                     => 100,
        date_start                 => $starting,
        date_pricing               => $starting - 600,
        duration                   => '30m',
        barrier                    => 'S0P',
        current_tick               => $tick,
        starts_as_forward_starting => 1
    };

    $bet = produce_contract($bet_params);

    ok($bet->is_valid_to_buy,  'Valid for purchase');
    ok($bet->is_valid_to_sell, '..and for sale-back');
};

subtest 'invalid underlying is a weak foundation' => sub {

    plan tests => 5;

    my $underlying = create_underlying('frxAUDUSD');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '3d',
        barrier      => 'S0P',
        current_tick => $tick,
    };

    BOM::Platform::Runtime->instance->app_config->system->suspend->trading(1);    # Cheese it, it's the cops!
    reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

    my $bet = produce_contract($bet_params);

    my $expected_reasons = [qr/^All trading suspended/];
    test_error_list('buy', $bet, $expected_reasons);
    BOM::Platform::Runtime->instance->app_config->system->suspend->trading(0);    # Resume betting!
    reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

    my $old_tick = Postgres::FeedDB::Spot::Tick->new({
        symbol => $bet->underlying->symbol,
        epoch  => $starting - 3600,
        quote  => 100
    });
    $bet_params->{current_tick} = $old_tick;

    $bet = produce_contract($bet_params);

    $expected_reasons = [qr/Quote.*too old/];
    test_error_list('buy', $bet, $expected_reasons);

    my $orig_trades = BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades;
    $bet_params->{current_tick} = $tick;
    $bet = produce_contract($bet_params);
    ok(BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades(['frxAUDUSD']), 'Suspending trading on this underlying.');
    reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

    $expected_reasons = [qr/^Underlying.*suspended/];
    test_error_list('buy', $bet, $expected_reasons);
    ok(BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades($orig_trades), 'Restoring trading to original state..');
    reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
};

subtest 'invalid bet payout hobbling around' => sub {
    plan tests => 5;

    my $underlying = create_underlying('frxAUDUSD');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 10000000.34,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '3d',
        barrier      => '100.085',
        current_tick => $tick,
    };
    my $bet = produce_contract($bet_params);

    my $expected_reasons = [qr/payout amount outside acceptable range.*/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{amount} = 0.75;
    $bet                  = produce_contract($bet_params);
    $expected_reasons     = [qr/stake.*is not within limits/];
    test_error_list('buy', $bet, $expected_reasons);
    ok($bet->primary_validation_error->message =~ $expected_reasons->[0], '..and the primary one is the most severe.');

    $bet_params->{amount} = 12.345;
    $bet                  = produce_contract($bet_params);
    $expected_reasons     = [qr/too many decimal places/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{currency} = 'USD';
    $bet_params->{amount}   = 20000;
    $bet                    = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we fix those things, it validates just fine.');
};

subtest 'invalid bet types are dull' => sub {
    plan tests => 1;

    my $underlying = create_underlying('frxAUDUSD');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'RANGE',
        currency     => 'USD',
        payout       => 200,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '4h',
        high_barrier => 'S100P',
        low_barrier  => 'S-100P',
        current_tick => $tick,
    };

    my $bet              = produce_contract($bet_params);
    my $expected_reasons = [qr/suspended for contract type/];
    test_error_list('buy', $bet, $expected_reasons);
};

subtest 'invalid contract stake evokes sympathy' => sub {
    plan tests => 6;

    my $underlying = create_underlying('frxAUDUSD');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 2,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '3d',
        barrier      => 1100,
        current_tick => $tick,
    };

    my $bet = produce_contract($bet_params);

    my $expected_reasons = [qr/Barrier too far from spot/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{amount}  = 20000;
    $bet_params->{barrier} = '100.001';
    $bet                   = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we ask for a higher payout, it validates just fine.');

    $bet_params->{duration} = '15m';
    $bet_params->{barrier}  = 'S100000500P';

    # Between setting up aggregated ticks and mocking objects, I chose the latter.
    # We are not checking volatility and trend calculation here.
    my $mocked_contract = Test::MockModule->new('BOM::Product::Contract::Call');
    $mocked_contract->mock('pricing_vol', sub { 0.1 });
    my $mocked_engine = Test::MockModule->new('BOM::Product::Pricing::Engine::Intraday::Forex');
    $mocked_engine->mock('ticks_for_trend', sub { [] });
    $bet = produce_contract($bet_params);
    is $bet->theo_probability->amount, 0, 'Theo probability can be zero if there are not ticks for forex intraday';
    $mocked_engine->unmock_all;
    $mocked_contract->unmock_all;

    $bet_params->{duration} = '11d';
    $bet_params->{barrier}  = '99.88';
    $bet_params->{bet_type} = 'ONETOUCH';

    $bet = produce_contract($bet_params);
    ok $bet->is_valid_to_buy, 'valid to buy with probability 0.997';
    $bet_params->{barrier} = 99.99;
    $bet                   = produce_contract($bet_params);
    $expected_reasons      = [qr/stake same as payout/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{amount_type} = 'stake';
    $bet_params->{amount}      = 0;
    $bet                       = produce_contract($bet_params);
    $expected_reasons          = [qr/Empty or zero stake/];
    test_error_list('buy', $bet, $expected_reasons);
};

subtest 'invalid barriers knocked down for great justice' => sub {
    plan tests => 7;

    my $underlying = create_underlying('frxAUDUSD');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'ONETOUCH',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '3d',
        barrier      => 'S0P',
        current_tick => $tick,
    };

    my $bet = produce_contract($bet_params);
    my $expected_reasons = [qr/move below minimum/, qr/barrier.*spot.*start/, qr/stake.*same as.*payout/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{barrier} = 110;
    $bet = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we ask for a further barrier, it validates just fine.');

    $bet_params->{bet_type}     = 'UPORDOWN';
    $bet_params->{high_barrier} = 100.001;
    $bet_params->{low_barrier}  = '99.99995';
    $bet_params->{duration}     = '7d';
    $bet                        = produce_contract($bet_params);
    $expected_reasons = [qr/stake.*same as.*payout/, qr/Barrier too far from spot/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{low_barrier} = -100;      # Fine, we'll set our low barrier like you want.
    $bet = produce_contract($bet_params);
    $expected_reasons = [qr/^Non-positive barrier/, qr/stake.*same as.*payout/, qr/Barrier too far from spot/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{low_barrier} = 111;       # Sigh, ok, then, what about this one?
    $bet = produce_contract($bet_params);
    $expected_reasons = [qr/barriers inverted/, qr/straddle.*spot/, qr/stake.*same as.*payout/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{high_barrier} = 110;
    $bet_params->{low_barrier}  = 110;                             # Surely this must be ok.
    $bet                        = produce_contract($bet_params);
    $expected_reasons = [qr/barriers must be different/, qr/straddle.*spot/, qr/stake.*same as.*payout/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{high_barrier} = 110;                             # Ok, I think I get it now.
    $bet_params->{low_barrier}  = 90;
    $bet                        = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but with properly set barriers, it validates just fine.');
};

subtest 'volsurfaces become old and invalid' => sub {
    plan tests => 8;

    my $underlying = create_underlying('frxAUDUSD');
    my $starting   = $oft_used_date->epoch + 10 * 86400;

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $underlying->symbol,
            recorded_date => Date::Utility->new($starting)->minus_time_interval('10d'),
        });

    my $tick = Postgres::FeedDB::Spot::Tick->new({
        symbol => 'frxAUDUSD',
        epoch  => $starting,
        quote  => 100
    });
    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'PUT',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '3d',
        barrier      => 'S0P',
        current_tick => $tick,
    };

    my $bet = produce_contract($bet_params);

    my $expected_reasons = [qr/volsurface too old/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{date_start}   = $oft_used_date->epoch;
    $bet_params->{date_pricing} = $oft_used_date->epoch;
    $bet                        = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we are close in time, validates just fine.');

    $starting = $oft_used_date->epoch + 5 * 3600 + 600;    # Intradays are even more sensitive.
    $starting += 4 * 86400;
    $tick = Postgres::FeedDB::Spot::Tick->new({
        symbol => 'frxAUDUSD',
        epoch  => $starting,
        quote  => 100
    });
    $bet_params = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '2m',
        barrier      => 'S0P',
        current_tick => $tick,
    };

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/volsurface too old/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{duration} = '1d';
    $bet = produce_contract($bet_params);
    ok($bet->volsurface->validation_error('fake broken surface'), 'Set broken surface');
    my $vol;
    warning { $vol = $bet->pricing_vol }, qr/Volatility error: fake broken surface/;
    ok $bet->primary_validation_error->message =~ qr/fake broken surface/, "correct error";

    my $volsurface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol         => 'GDAXI',
            recorded_date  => Date::Utility->new('2013-03-27 06:00:34'),
            spot_reference => $tick->quote,
        });
    my $gdaxi = create_underlying('GDAXI');
    my $surface_too_old_date = $trading_calendar->opening_on($gdaxi->exchange, Date::Utility->new('2013-03-28'));
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'GDAXI',
            date          => Date::Utility->new,
            recorded_date => $surface_too_old_date->plus_time_interval('2h23m20s')});

    $bet_params->{underlying}   = $gdaxi;
    $bet_params->{date_start}   = $bet_params->{date_pricing} = $surface_too_old_date->plus_time_interval('2h23m20s');
    $bet_params->{bet_type}     = 'ONETOUCH';
    $bet_params->{barrier}      = 103;
    $bet_params->{duration}     = '14d';
    $bet_params->{volsurface}   = $volsurface;
    $bet_params->{current_tick} = $tick;
    $bet                        = produce_contract($bet_params);
    $expected_reasons           = [qr/volsurface too old/];

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix',
        {recorded_date => Date::Utility->new($bet_params->{date_pricing})});

    test_error_list('buy', $bet, $expected_reasons);

    my $forced_vol = '0.10';
    $bet_params->{volsurface} = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol         => 'GDAXI',
            recorded_date  => $bet_params->{date_pricing},
            spot_reference => $tick->quote,
        });
    $bet_params->{pricing_vol} = $forced_vol;
    $bet = produce_contract($bet_params);
    is($bet->_pricing_args->{iv}, $forced_vol, 'Pricing args contains proper forced vol.');
    $expected_reasons = [qr/forced \(not calculated\) IV/];
    my $valid_to_buy;
    warning { $valid_to_buy = $bet->is_valid_to_buy }, qr/spot too far from surface reference/;
    ok $valid_to_buy, 'valid to buy with forced vol';
};

subtest 'invalid start times' => sub {
    plan tests => 9;

    my $underlying = create_underlying('frxAUDUSD');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'ONETOUCH',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting - 300,
        duration     => '3d',
        barrier      => '110',
        current_tick => $tick,
    };
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix',
        {recorded_date => Date::Utility->new($bet_params->{date_pricing})});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxAUDUSD',
            recorded_date => Date::Utility->new($bet_params->{date_start}),
        });

    my $bet = produce_contract($bet_params);

    my $expected_reasons = [qr/^Forward time for non-forward-starting/,];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{date_pricing} = $starting;
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix',
        {recorded_date => Date::Utility->new($bet_params->{date_pricing})});

    $bet = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we are starting now, validates just fine.');

    $bet_params->{bet_type} = 'CALL';
    $bet_params->{duration} = '-1m';

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/Start must be before expiry/,];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{duration} = '6d';

    $bet = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when back to the future, validates just fine.');

    $bet_params->{underlying}   = create_underlying('frxEURUSD');
    $bet_params->{duration}     = '10m';
    $bet_params->{bet_type}     = 'CALL';
    $bet_params->{date_pricing} = $starting - 30;
    $bet_params->{barrier}      = 'S0P';

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix',
        {recorded_date => Date::Utility->new($bet_params->{date_pricing})});

    $bet_params->{entry_tick} = $tick;
    $bet                      = produce_contract($bet_params);
    $expected_reasons         = [qr/forward-starting.*blackout/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{date_pricing} = $starting + 45;
    $bet_params->{bet_type}     = 'CALL';
    $bet_params->{duration}     = '3d';

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/starts in the past/];
    test_error_list('buy', $bet, $expected_reasons);

    $underlying = create_underlying('GDAXI');

    $bet_params->{underlying}   = $underlying;
    $bet_params->{bet_type}     = 'PUT';
    $bet_params->{duration}     = '7d';
    $bet_params->{date_start}   = $trading_calendar->opening_on($underlying->exchange, Date::Utility->new('2013-03-28'));
    $bet_params->{date_pricing} = $bet_params->{date_start};
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'GDAXI',
            date          => Date::Utility->new,
            recorded_date => Date::Utility->new($bet_params->{date_pricing})});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix',
        {recorded_date => Date::Utility->new($bet_params->{date_pricing})});

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/blackout period \[symbol: GDAXI\] \[from: 1364457600\] \[to: 1364458200\]/];
    test_error_list('buy', $bet, $expected_reasons);

    my $volsurface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol         => 'GDAXI',
            recorded_date  => Date::Utility->new('2013-03-30 15:00:34'),
            spot_reference => $tick->quote,
        });

    $bet_params->{volsurface}   = $volsurface;
    $bet_params->{bet_type}     = 'PUT';
    $bet_params->{duration}     = '0d';
    $bet_params->{date_start}   = $trading_calendar->closing_on($underlying->exchange, Date::Utility->new('2013-03-28'))->minus_time_interval('1m');
    $bet_params->{is_intraday}  = 0;
    $bet_params->{expiry_daily} = 1;
    $bet_params->{date_pricing} = $bet_params->{date_start};
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'GDAXI',
            date          => Date::Utility->new,
            recorded_date => Date::Utility->new($bet_params->{date_pricing})});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix',
        {recorded_date => Date::Utility->new($bet_params->{date_pricing})});
    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/blackout period/];
    my $mocked = Test::MockModule->new('BOM::Product::Contract');
    $mocked->mock('_validate_lifetime', sub { note "mocked lifetime"; return; });

    test_error_list('buy', $bet, $expected_reasons);
    $mocked->unmock_all;

    $volsurface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol         => 'GDAXI',
            recorded_date  => Date::Utility->new('2013-03-30 11:00:34'),
            spot_reference => $tick->quote,
        });

    $bet_params->{date_start}   = Date::Utility->new('2013-03-30 12:34:56');    # It's a Saturday!
    $bet_params->{duration}     = '5d';
    $bet_params->{date_pricing} = $bet_params->{date_start};
    $bet_params->{volsurface}   = $volsurface;
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'GDAXI',
            date          => Date::Utility->new,
            recorded_date => Date::Utility->new($bet_params->{date_pricing})});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix',
        {recorded_date => Date::Utility->new($bet_params->{date_pricing})});

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/underlying.*closed/];
    test_error_list('buy', $bet, $expected_reasons);
};

subtest 'invalid expiry times' => sub {
    plan tests => 5;

    my $underlying = create_underlying('frxAUDUSD');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'PUT',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting,
        date_expiry  => $oft_used_date->truncate_to_day->plus_time_interval('1d23h59m59s'),
        barrier      => 'S0P',
        current_tick => $tick,
    };
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix',
        {recorded_date => Date::Utility->new($bet_params->{date_pricing})});

    my $bet              = produce_contract($bet_params);
    my $expected_reasons = [qr/^Exchange is closed on expiry date/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{duration} = '3d';
    $bet = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we are open at the end, validates just fine.');

    # Need a quotdian here.
    $underlying               = create_underlying('RDBULL');
    $bet_params->{underlying} = $underlying;
    $bet_params->{bet_type}   = 'CALL';
    $bet_params->{duration}   = '10h';
    $bet_params->{date_start} = $trading_calendar->closing_on($underlying->exchange, Date::Utility->new('2013-03-28'))->minus_time_interval('9h');
    $bet_params->{date_pricing} = $bet_params->{date_start}->epoch - 1776;
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix',
        {recorded_date => Date::Utility->new($bet_params->{date_pricing})});

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/must expire on same day/];
    test_error_list('buy', $bet, $expected_reasons);

    $underlying = create_underlying('GDAXI');

    my $volsurface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol         => 'GDAXI',
            recorded_date  => Date::Utility->new('2013-03-28 15:00:34'),
            spot_reference => $tick->quote,
        });

    $bet_params->{volsurface}   = $volsurface;
    $bet_params->{underlying}   = $underlying;
    $bet_params->{duration}     = '2h';
    $bet_params->{date_start}   = $trading_calendar->closing_on($underlying->exchange, Date::Utility->new('2013-03-28'))->minus_time_interval('1h');
    $bet_params->{date_pricing} = $bet_params->{date_start}->epoch - 1066;
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix',
        {recorded_date => Date::Utility->new($bet_params->{date_pricing})});

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/closed at expiry/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{duration} = '59m34s';

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/blackout period \[symbol: GDAXI\] \[from: 1364488140\] \[to: 1364488200\]/];
    test_error_list('buy', $bet, $expected_reasons);

};

subtest 'invalid lifetimes.. how rude' => sub {
    my $underlying = create_underlying('frxEURUSD');
    my $starting   = $oft_used_date->epoch - 3600;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting - 900,
        duration     => '21s',
        barrier      => 'S0P',
        current_tick => $tick,
    };

    my $dt_starting = Date::Utility->new($bet_params->{date_pricing});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix',
        {recorded_date => Date::Utility->new($bet_params->{date_pricing})});

    my $bet              = produce_contract($bet_params);
    my $expected_reasons = [qr/Intraday duration.*not acceptable/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{duration} = '20m';
    $bet = produce_contract($bet_params);

    ok($bet->is_valid_to_buy, '..but when we pick a longer duration, validates just fine.');

    $bet_params->{bet_type}     = 'CALL';
    $bet_params->{duration}     = '369d';
    $bet_params->{date_start}   = $starting - 86400;
    $bet_params->{date_pricing} = $starting - 86400;

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxEURUSD',
            recorded_date => Date::Utility->new($bet_params->{date_start}),
        });

    $bet = produce_contract($bet_params);

    $expected_reasons = [qr/Daily duration.*outside.*range/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{duration} = '181d';
    $bet = produce_contract($bet_params);

    ok($bet->is_valid_to_buy, '..but when we pick a shorter duration, validates just fine.');

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix', {recorded_date => Date::Utility->new($bet_params->{date_start})});
    $underlying = create_underlying('GDAXI');
    $bet_params->{underlying} = $underlying;
    $bet_params->{date_start} = $trading_calendar->opening_on($underlying->exchange, Date::Utility->new('6-Dec-12'))->plus_time_interval('15m');
    $bet_params->{date_pricing} = $bet_params->{date_start};
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'GDAXI',
            date          => Date::Utility->new,
            recorded_date => Date::Utility->new($bet_params->{date_pricing})});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix',
        {recorded_date => Date::Utility->new($bet_params->{date_pricing})});

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol         => 'GDAXI',
            recorded_date  => Date::Utility->new($bet_params->{date_pricing}),
            spot_reference => $tick->quote,
        });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol         => 'frxEURUSD',
            recorded_date  => Date::Utility->new($bet_params->{date_pricing}),
            spot_reference => $tick->quote,
        });

    $bet = produce_contract($bet_params);
    my $valid_to_buy;
    warning { $valid_to_buy = $bet->is_valid_to_buy }, qr/spot too far from surface reference/;
    ok($valid_to_buy, '..but when we pick an earlier start date, validates just fine.');

    $bet_params->{bet_type} = 'CALL';
    $bet_params->{duration} = '1d';
    $bet_params->{barrier}  = 101;
    $bet                    = produce_contract($bet_params);
    $expected_reasons       = [qr/Daily duration.*outside acceptable range/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{duration} = '14d';
    $bet = produce_contract($bet_params);
    warning { $valid_to_buy = $bet->is_valid_to_buy }, qr/spot too far from surface reference/;
    ok($valid_to_buy, '..but when we pick a reasonable duration, validates just fine.');

    my $volsurface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol         => 'GDAXI',
            recorded_date  => Date::Utility->new('2013-03-28 06:00:34'),
            spot_reference => $tick->quote,
        });

    $bet_params->{date_start}   = $trading_calendar->opening_on($underlying->exchange, Date::Utility->new('28-Mar-13'))->plus_time_interval('15m');
    $bet_params->{date_pricing} = $bet_params->{date_start};
    $bet_params->{duration}     = '8d';
    $bet_params->{barrier}      = 101;
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'GDAXI',
            date          => Date::Utility->new,
            recorded_date => Date::Utility->new($bet_params->{date_pricing})});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix',
        {recorded_date => Date::Utility->new($bet_params->{date_pricing})});
    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/enough trading.*calendar days/];
    test_error_list('buy', $bet, $expected_reasons);
};

subtest '10% barrier check for double barrier contract' => sub {
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $an_hour_earlier,
        }) for (qw/GBP USD/);

    my $now = Date::Utility->new('2014-10-08 10:00:00');

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxGBPUSD',
            recorded_date => $now
        });

    my $tick_params = {
        symbol => 'not_checked',
        epoch  => $now->epoch,
        quote  => 100
    };

    my $tick       = Postgres::FeedDB::Spot::Tick->new($tick_params);
    my $bet_params = {
        underlying   => 'frxGBPUSD',
        bet_type     => 'UPORDOWN',
        currency     => 'USD',
        payout       => 100,
        date_start   => $now,
        date_pricing => $now,
        duration     => '1d',
        high_barrier => '101',
        low_barrier  => '10',
        current_tick => $tick,
    };
    my $c                = produce_contract($bet_params);
    my $expected_reasons = [qr/Barrier too far from spot/];
    test_error_list('buy', $c, $expected_reasons);
};

subtest 'intraday indices duration test' => sub {
    my $now = Date::Utility->new('2015-04-08 00:30:00');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol         => 'AS51',
            recorded_date  => $now,
            spot_reference => $tick->quote,
        });

    my $tick_params = {
        symbol => 'not_checked',
        epoch  => $now->epoch,
        quote  => 100
    };

    for (my $i = 1800; $i > 0; $i -= 5) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $now->epoch - $i,
            underlying => 'AS51',
            quote      => 100.012,
            bid        => 100.015,
            ask        => 100.021
        });
    }
    my $tick   = Postgres::FeedDB::Spot::Tick->new($tick_params);
    my $params = {
        bet_type     => 'CALL',
        underlying   => 'AS51',
        date_start   => $now,
        date_pricing => $now,
        duration     => '15m',
        currency     => 'AUD',
        current_tick => $tick,
        payout       => 100,
        barrier      => 'S0P',
    };
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'AS51',
            recorded_date => $now,
        });

    my $c = produce_contract($params);
    my $valid_to_buy;
    warning { $valid_to_buy = $c->is_valid_to_buy }, qr/spot too far from surface reference/;
    ok $valid_to_buy, 'valid 15 minutes Flash on AS51';

    $params->{duration} = '14m';
    $c = produce_contract($params);
    my $expected_reasons = [qr/Intraday duration.*not acceptable/];
    test_error_list('buy', $c, $expected_reasons);
    $params->{duration} = '5h1s';
    $c                  = produce_contract($params);
    $expected_reasons   = [qr/Intraday duration.*not acceptable/];
    test_error_list('buy', $c, $expected_reasons);

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'GDAXI',
            recorded_date => Date::Utility->new($params->{date_pricing}),
        });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => 'GBP',
            recorded_date => $an_hour_earlier,
        });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol         => 'GDAXI',
            recorded_date  => $now,
            spot_reference => $tick->quote,
        });
    $params->{date_start} = Date::Utility->new('2015-04-08 07:15:00');
    my $ftse_tick = Postgres::FeedDB::Spot::Tick->new({
        epoch      => $params->{date_start}->epoch,
        underlying => 'GDAXI',
        quote      => 100.012,
        bid        => 100.015,
        ask        => 100.021
    });

    $params->{date_pricing} = $params->{date_start};
    $params->{underlying}   = 'GDAXI';
    $params->{currency}     = 'GBP';
    $params->{duration}     = '14m59s';
    $params->{current_tick} = $ftse_tick;
    $c                      = produce_contract($params);
    $expected_reasons       = [qr/Intraday duration.*not acceptable/];
    test_error_list('buy', $c, $expected_reasons);
};

subtest 'expiry_daily expiration time' => sub {
    my $now         = Date::Utility->new('2014-10-08 00:15:00');
    my $tick_params = {
        symbol => 'not_checked',
        epoch  => $now->epoch,
        quote  => 100
    };
    my $tick   = Postgres::FeedDB::Spot::Tick->new($tick_params);
    my $params = {
        bet_type     => 'CALL',
        underlying   => 'AS51',
        date_start   => $now,
        date_pricing => $now,
        duration     => '23h',
        currency     => 'AUD',
        current_tick => $tick,
        payout       => 100,
        barrier      => 'S0P',
    };
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'AS51',
            recorded_date => Date::Utility->new($params->{date_pricing}),
        });
    my $c = produce_contract($params);
    ok $c->_validate_trading_times;
    is_deeply(($c->_validate_trading_times)[0]->{message_to_client},
        ['Contracts on this market with a duration of under 24 hours must expire on the same trading day.']);
};

subtest 'spot reference check' => sub {

    my $now        = Date::Utility->new('2015-10-20 13:41:00');
    my $volsurface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol         => 'DJI',
            recorded_date  => $now,
            spot_reference => 94.9,
        });
    my $tick_params = {
        symbol => 'DJI',
        epoch  => $now->epoch,
        quote  => 100
    };

    my $tick       = Postgres::FeedDB::Spot::Tick->new($tick_params);
    my $bet_params = {
        underlying   => 'DJI',
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        date_start   => $now,
        date_pricing => $now,
        duration     => '3d',
        barrier      => 'S0P',
        current_tick => $tick,
        volsurface   => $volsurface,
    };
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'DJI',
            recorded_date => Date::Utility->new($bet_params->{date_pricing}),
        });
    my $c                = produce_contract($bet_params);
    my $expected_reasons = [qr/spot too far from surface reference/];
    test_error_list('buy', $c, $expected_reasons);
};

subtest 'zero vol' => sub {
    my $now        = Date::Utility->new('2016-01-27');
    my $volsurface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol  => 'frxAUDUSD',
            surface => {
                7 => {
                    smile => {
                        25 => 0,
                        50 => 0,
                        75 => 0,
                    },
                },
            },
            recorded_date => $now,
        });

    my $c = produce_contract({
        bet_type     => 'ONETOUCH',
        underlying   => 'frxAUDUSD',
        date_start   => $now,
        date_pricing => $now,
        duration     => '6d',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 1000,
    });
    is $c->pricing_vol, 0, 'pricing vol is zero';
    like($c->primary_validation_error->message, qr/Zero volatility/, 'error');
};

subtest 'tentative events' => sub {
    #Make sure there is no blackout period
    my $now = Date::Utility->new('2016-03-18 05:00:00');
    set_absolute_time($now->epoch);
    my $blackout_start = $now->minus_time_interval('1h');
    my $blackout_end   = $now->plus_time_interval('1h');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'economic_events',
        {
            recorded_date => Date::Utility->new(),
            events        => [{
                    symbol       => 'USD',
                    release_date => $now->epoch,
                    blankout     => $blackout_start->epoch,
                    estimated_release_date => $now->epoch,
                    blankout_end => $blackout_end->epoch,
                    is_tentative => 1,
                    event_name   => 'Test tentative',
                    impact       => 5,
                }
            ],
        });
    my $contract_args = {
        underlying => 'frxAUDUSD',
        bet_type   => 'CALL',
        barrier    => 'S0P',
        duration   => '2m',
        payout     => 10,
        currency   => 'USD',
    };
    $contract_args->{date_pricing} = $contract_args->{date_start} = $blackout_start->minus_time_interval('2m1s');
    my $c = produce_contract($contract_args);
    ok !$c->_validate_start_and_expiry_date, 'no error if contract expiring 1 second before tentative event\'s blackout period';
    $contract_args->{date_pricing} = $contract_args->{date_start} = $blackout_start->minus_time_interval('2m');
    $c = produce_contract($contract_args);
    ok !$c->_validate_start_and_expiry_date, 'no error if contract is atm';
    $contract_args->{barrier} = 'S20P';

    $c = produce_contract({%$contract_args, underlying => 'frxGBPCHF'});
    ok !$c->_validate_start_and_expiry_date, 'no error if event is not affecting the underlying';

    $contract_args->{date_pricing} = $contract_args->{date_start} = $blackout_end->minus_time_interval('1s');
    $c = produce_contract($contract_args);
    ok !$c->_validate_start_and_expiry_date, 'Does not throw error if contract starts on tentative event\'s blackout end';

    $contract_args->{date_pricing} = $contract_args->{date_start} = $blackout_start->minus_time_interval('1s');
    delete $contract_args->{duration};
    $contract_args->{date_expiry} = $blackout_end->plus_time_interval('1s');
    $c = produce_contract($contract_args);
    ok !$c->_validate_start_and_expiry_date, 'no error';
};

subtest 'integer barrier' => sub {
    my $now = Date::Utility->new('2015-04-08 00:30:00');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol         => 'AS51',
            recorded_date  => $now,
            spot_reference => $tick->quote,
        });

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'AS51',
            recorded_date => $now,
        });
    my $tick_params = {
        symbol => 'not_checked',
        epoch  => $now->epoch,
        quote  => 100
    };

    my $tick   = Postgres::FeedDB::Spot::Tick->new($tick_params);
    my $params = {
        bet_type     => 'CALL',
        underlying   => 'AS51',
        date_start   => $now,
        date_pricing => $now,
        duration     => '1d',
        currency     => 'AUD',
        current_tick => $tick,
        payout       => 100,
        barrier      => 100,
    };

    my $c = produce_contract($params);
    my $valid_to_buy;
    warning { $valid_to_buy = $c->is_valid_to_buy }, qr/spot too far from surface reference/;
    ok $valid_to_buy, 'valid to buy if barrier is integer for indices';

    $params->{barrier} = 100.1;
    $c = produce_contract($params);
    warning { $valid_to_buy = $c->is_valid_to_buy }, qr/spot too far from surface reference/;
    ok !$valid_to_buy, 'not valid to buy if barrier is non integer';
    like($c->primary_validation_error->message, qr/Barrier is not an integer/, 'correct error');

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $now,
        }) for qw(frxAUDUSD frxAUDJPY frxAUDUSD);
    $params->{underlying}   = 'frxAUDUSD';
    $params->{date_pricing} = $now;
    $c                      = produce_contract($params);

    warning { $valid_to_buy = $c->is_valid_to_buy }, qr/spot too far from surface reference/;
    ok $valid_to_buy, 'valid to buy if barrier is non integer for forex';
};

subtest 'contract must be held' => sub {
    my $args = {
        underlying   => 'R_100',
        bet_type     => 'CALL',
        barrier      => 'S0P',
        duration     => '15m',
        currency     => 'USD',
        payout       => 100,
        current_tick => $tick,
        entry_tick   => $tick,
        date_start   => $oft_used_date,
        date_pricing => $oft_used_date->epoch + 1,
    };
    my $c = produce_contract($args);
    ok $c->is_valid_to_sell, 'valid to sell';

    $args->{_date_pricing_milliseconds} = $oft_used_date->epoch + 0.1;
    $args->{date_pricing}               = $oft_used_date->epoch;
    $c                                  = produce_contract($args);
    ok !$c->pricing_new, 'not pricing_new if it is 0.1 second from start';
    ok $c->is_valid_to_sell, 'valid to sell right after buy';
    delete $args->{$_} for qw(date_pricing _date_pricing_milliseconds);
    # we set pricing_new to true if date_start is not provided.
    delete $args->{date_start};
    $c = produce_contract($args);
    ok $c->pricing_new, 'is pricing_new when date_pricing == date_start';
    ok $c->date_pricing->epoch == $c->date_start->epoch, 'date_pricing == date_start when pricing_new is set';
};

subtest 'zero payout' => sub {

#create an empty un-used even so ask_price won't fail preparing market data for pricing engine
#Because the code to prepare market data is called for all pricings in Contract
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

    lives_ok {
        my $fake_tick = Postgres::FeedDB::Spot::Tick->new({
            underlying => 'R_100',
            epoch      => time,
            quote      => 100,
        });
        my $c = produce_contract({
            bet_type     => 'CALL',
            underlying   => 'R_100',
            barrier      => 'S0P',
            currency     => 'USD',
            payout       => 0,
            duration     => '15m',
            current_tick => $fake_tick,
            entry_tick   => $fake_tick,
        });
        ok !$c->is_valid_to_buy, 'not valid to buy';
        like($c->primary_validation_error->{message}, qr/Empty or zero stake/, 'throws error');
    }
    'does not die if payout is zero';
};

my $now       = Date::Utility->new;
my $fake_tick = Postgres::FeedDB::Spot::Tick->new({
    underlying => 'R_100',
    epoch      => $now->epoch,
    quote      => 100,
});

subtest 'sellback tick expiry contracts' => sub {
    my $params = {
        bet_type     => 'CALL',
        barrier      => 'S0P',
        underlying   => 'R_100',
        duration     => '5t',
        date_start   => $now,
        date_pricing => $now->epoch + 1,
        currency     => 'USD',
        payout       => 10,
        current_tick => $fake_tick,
        entry_tick   => $fake_tick,
    };
    my $c = produce_contract($params);
    ok !$c->is_valid_to_sell, 'not valid to sell';
    like($c->primary_validation_error->{message}, qr/resale of tick expiry contract/, 'throws error');
    $params->{exit_tick} = Postgres::FeedDB::Spot::Tick->new({
        underlying => 'R_100',
        epoch      => $now->epoch + 10,
        quote      => 101,
    });
    $params->{date_pricing} = $now->epoch + 11;
    $c = produce_contract($params);
    ok $c->is_expired,       'expired';
    ok $c->is_valid_to_sell, 'valid to sell';
};

subtest 'invalid digits barrier' => sub {
    my $params = {
        bet_type     => 'DIGITOVER',
        underlying   => 'R_100',
        duration     => '10t',
        currency     => 'USD',
        current_tick => $fake_tick,
        entry_tick   => $fake_tick,
        barrier      => 'S0P',
        payout       => 10,
    };
    my $c = produce_contract($params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->{message}, qr/invalid supplied barrier format for digits/, 'throws error');
    $params->{barrier} = 0;
    $c = produce_contract($params);
    ok $c->is_valid_to_buy, 'valid to buy';
};
subtest 'entry tick validation' => sub {

    plan tests => 4;

    my $underlying = create_underlying('frxAUDUSD');
    my $starting   = Date::Utility->new('2014-10-08 13:00:00');

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxAUDUSD',
            recorded_date => $starting,
        });
    my $tick = Postgres::FeedDB::Spot::Tick->new({
        underlying => 'frxAUDUSD',
        epoch      => $starting->epoch,
        quote      => 100,
    });
    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting->epoch + 1,
        duration     => '2d',
        barrier      => 'S0P',
        current_tick => $tick,
    };

    my $bet = produce_contract($bet_params);
    ok !$bet->is_valid_to_sell, 'not valid to sell';
    like($bet->primary_validation_error->{message}, qr/Waiting for entry tick/, 'throws error');

    $bet_params->{starts_as_forward_starting} = 1;
    $bet = produce_contract($bet_params);
    ok $bet->is_valid_to_sell, 'valid to sell for forward starting even no entry tick';

    delete $bet_params->{starts_as_forward_starting};
    $bet_params->{entry_tick} = $tick;
    $bet = produce_contract($bet_params);
    ok $bet->is_valid_to_sell, 'valid to sell with  entry tick';

};

# Let's not surprise anyone else
ok(BOM::Platform::Runtime->instance->app_config->quants->features->suspend_contract_types($orig_suspended),
    'Switched RANGE bets back on, if they were.');

my $counter = 0;

sub test_error_list {
    my ($which, $bet, $expected) = @_;
    $counter++;
    my $val_method = 'is_valid_to_' . lc $which;
    subtest $bet->shortcode . ' error confirmation' => sub {
        plan tests => 2;

        my $res;
        warning { $res = $bet->$val_method }, qr/Quote too old for/;
        ok(!$res, 'Not valid for ' . $which);
        if ($bet->primary_validation_error->message =~ $expected->[0]) {
            pass 'error is expected';
        } else {
            fail 'expected: ' . $expected->[0] . ' got: ' . $bet->primary_validation_error->message;
        }
    };
}

done_testing;
