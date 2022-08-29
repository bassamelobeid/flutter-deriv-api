use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::MockModule;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData               qw(create_underlying);
use BOM::MarketData::Types;
use Date::Utility;

use BOM::Config::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Config::Chronicle;
use Quant::Framework;
use Quant::Framework::VolSurface::Utils qw(NY1700_rollover_date_on);

initialize_realtime_ticks_db;
my $mocked = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + 0.005 * $_} } (0 .. 80)];
    });

my $trading_calendar    = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader);
my $weekday             = Date::Utility->new('2016-03-29');
my $usdjpy_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxAUDUSD',
    epoch      => $weekday->epoch
});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $weekday});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $weekday
    }) for qw(USD JPY HKD AUD-USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'OTC_HSI',
        recorded_date => $weekday
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $weekday
    }) for qw(frxAUDUSD frxUSDHKD frxAUDHKD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'OTC_HSI',
        recorded_date => $weekday
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'correlation_matrix',
    {
        recorded_date => $weekday,
        symbol        => 'indices',
        correlations  => {
            'OTC_HSI' => {
                USD => {
                    '3M'  => 0.1,
                    '12M' => 0.1
                },
                GBP => {
                    '3M'  => 0.1,
                    '12M' => 0.1
                },
                AUD => {
                    '3M'  => 0.1,
                    '12M' => 0.1
                },
                EUR => {
                    '3M'  => 0.1,
                    '12M' => 0.1
                },
            }}});

subtest 'date start blackouts' => sub {
    my $mocked = Test::MockModule->new('BOM::Product::Contract');
    $mocked->mock('market_is_inefficient', sub { 0 });
    note('Testing date_start blackouts for frxAUDUSD');
    my $one_second_since_open = $weekday->plus_time_interval('1s');
    my $bet_params            = {
        bet_type     => 'CALL',
        underlying   => 'frxAUDUSD',
        currency     => 'USD',
        payout       => 10,
        barrier      => 'S0P',
        date_pricing => $one_second_since_open,
        date_start   => $one_second_since_open,
        duration     => '6h',
        current_tick => $usdjpy_weekday_tick,
    };
    my $c = produce_contract($bet_params);
    ok !$c->underlying->sod_blackout_start, 'no start of day blackout';
    ok $c->is_valid_to_buy,                 'valid to buy';

    my $one_second_before_close = $weekday->plus_time_interval('1d')->minus_time_interval('1s');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $one_second_before_close,
        }) for qw(frxAUDUSD frxUSDHKD);
    $usdjpy_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxAUDUSD',
        quote      => 100,
        epoch      => $one_second_before_close->epoch
    });
    $bet_params->{date_pricing} = $bet_params->{date_start} = $one_second_before_close;
    $bet_params->{current_tick} = $usdjpy_weekday_tick;
    $c                          = produce_contract($bet_params);
    ok !$c->underlying->eod_blackout_start, 'no end of day blackout';
    ok $c->is_valid_to_buy,                 'valid to buy';

    note('Testing date_start blackouts for frxAUDUSD tick expiry contract');
    my $few_second_before_close = $weekday->plus_time_interval('2d')->minus_time_interval('2m');

    use Test::MockModule;
    my $usdjpy_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxAUDUSD',
        quote      => 100,
        epoch      => $few_second_before_close->epoch
    });
    $bet_params = {
        bet_type     => 'CALL',
        underlying   => 'frxAUDUSD',
        currency     => 'USD',
        barrier      => 'S0P',
        payout       => 10,
        date_pricing => $few_second_before_close,
        date_start   => $few_second_before_close,
        duration     => '5t',
        current_tick => $usdjpy_tick,
        entry_tick   => $usdjpy_tick
    };

    $c = produce_contract($bet_params);
    # the reason we mock it here is because to get tick expiry pricing work, it need proper Aggtick setup which need to dump a lots of tick
    # since this test is mainly test for blackout period, it is not matter what price it is .
    $mocked = Test::MockModule->new('BOM::Product::Contract::Call');
    $mocked->mock('market_is_inefficient', sub { 0 });
    $mocked->mock(
        'theo_probability',
        Math::Util::CalculatedValue::Validatable->new({
                name        => 'ask_probability',
                description => 'test ask probability',
                set_by      => 'test',
                base_amount => '0.5',
            }));
    $mocked->mock(
        'ask_probability',
        Math::Util::CalculatedValue::Validatable->new({
                name        => 'ask_probability',
                description => 'test ask probability',
                set_by      => 'test',
                base_amount => '0.1',
            }));
    ok !$c->is_valid_to_buy, 'invalid to buy at one second before 30-Mar-16 close';

    my $friday_close                     = Date::Utility->new('2016-04-01 20:55:00');
    my $ten_minute_before_friday_close   = $friday_close->minus_time_interval('10m');
    my $three_minute_before_friday_close = $friday_close->minus_time_interval('3m');

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxAUDUSD',
            recorded_date => $_,
        }) for ($ten_minute_before_friday_close, $three_minute_before_friday_close);
    my $usdjpy_friday_ten_minute_before_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxAUDUSD',
        epoch      => $ten_minute_before_friday_close->epoch
    });
    $bet_params->{date_pricing} = $bet_params->{date_start} = $ten_minute_before_friday_close;
    $bet_params->{current_tick} = $usdjpy_friday_ten_minute_before_tick;
    $c                          = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy at 10 min before friday close';

    my $usdjpy_friday_three_minute_before_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxAUDUSD',
        epoch      => $three_minute_before_friday_close->epoch
    });
    $bet_params->{date_pricing} = $bet_params->{date_start} = $three_minute_before_friday_close;
    $bet_params->{current_tick} = $usdjpy_friday_three_minute_before_tick;
    $c                          = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy at 3 mins before friday close';
    is_deeply(($c->primary_validation_error)[0]->{message_to_client}, ['Trading is not available from [_1] to [_2].', '20:50:00', '20:55:00']);
    is_deeply $c->primary_validation_error->{details}, {field => 'date_start'}, 'error detials is not correct';

    note('Testing date_start blackouts for frxAUDUSD on Monday ');

    $bet_params->{date_start} = Date::Utility->new('2016-04-04');
    $bet_params->{duration}   = '10m';
    $c                        = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy at 10 mins forward starting of forex on Monday morning';
    is_deeply(($c->primary_validation_error)[0]->{message_to_client}, ['Trading is not available from [_1] to [_2].', '00:00:00', '00:10:00']);
    is_deeply $c->primary_validation_error->{details}, {field => 'date_start'}, 'error detials is not correct';

    $bet_params->{underlying} = 'R_100';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'is valid to buy at 10 mins forward starting of random on Monday morning';

    $bet_params->{date_start} = Date::Utility->new('2016-04-05 00:00:00');
    $bet_params->{duration}   = '10m';
    $c                        = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy at 10 mins forward starting of forex on Tuesday morning';

    my $one_second_after_monday             = Date::Utility->new('2016-04-04 00:00:00');
    my $usdjpy_one_second_after_monday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxAUDUSD',
        epoch      => $one_second_after_monday->epoch
    });
    $bet_params->{date_pricing} = $bet_params->{date_start} = $one_second_after_monday;
    $bet_params->{current_tick} = $usdjpy_one_second_after_monday_tick;
    $c                          = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy a start now contract on Monday morning';

    note('Testing date_start blackouts for OTC_HSI');
    my $hsi              = create_underlying('OTC_HSI');
    my $hsi_open         = $trading_calendar->opening_on($hsi->exchange, $weekday);
    my $hsi_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'OTC_HSI',
        epoch      => $hsi_open->epoch + 600,
        quote      => 7195,
    });
    $bet_params->{underlying}   = 'OTC_HSI';
    $bet_params->{current_tick} = $hsi_weekday_tick;
    $bet_params->{date_start}   = $bet_params->{date_pricing} = $hsi_open->epoch + 599;
    $bet_params->{duration}     = '1h';
    $c                          = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is_deeply(($c->primary_validation_error)[0]->{message_to_client}, ['Trading is not available from [_1] to [_2].', '01:30:00', '01:40:00']);
    is_deeply $c->primary_validation_error->{details}, {field => 'date_start'}, 'error detials is not correct';
    $bet_params->{date_pricing} = $hsi_open->plus_time_interval('1m');
    $bet_params->{date_start}   = $hsi_open->epoch + 600;
    $bet_params->{duration}     = '1h';
    $c                          = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy forward starting contract on first 1 minute of opening';
    my $hsi_close = $trading_calendar->closing_on($hsi->exchange, $weekday);
    $hsi_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'OTC_HSI',
        epoch      => $hsi_close->epoch - 900,
        quote      => 7195,
    });
    $bet_params->{date_start}   = $bet_params->{date_pricing} = $hsi_close->epoch - 900;
    $bet_params->{duration}     = '15m';
    $bet_params->{current_tick} = $hsi_weekday_tick;
    $c                          = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is_deeply(($c->primary_validation_error)[0]->{message_to_client}, ['Trading is not available from [_1] to [_2].', '07:45:00', '08:00:00']);
    is_deeply $c->primary_validation_error->{details}, {field => 'date_start'}, 'error detials is not correct';

    note('Multiday contract on OTC_HSI');
    my $new_day           = $weekday->plus_time_interval('1d');
    my $hour_before_close = $trading_calendar->closing_on($hsi->exchange, $new_day)->minus_time_interval('1h');
    $hsi_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'OTC_HSI',
        epoch      => $hour_before_close->epoch,
        quote      => 7195,
    });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'OTC_HSI',
            recorded_date => $hour_before_close
        });
    $bet_params->{current_tick} = $hsi_weekday_tick;
    $bet_params->{date_start}   = $bet_params->{date_pricing} = $hour_before_close;
    $bet_params->{duration}     = '8d';
    $c                          = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{barrier} = 7200;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{duration} = '5d';

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $hour_before_close
        }) for qw(frxAUDUSD frxUSDHKD);
    $bet_params->{underlying} = 'frxAUDUSD';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{date_start} = $bet_params->{date_pricing} = $hour_before_close->epoch - 1;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';

    Cache::RedisDB->flushall;
    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;
    my $rollover    = NY1700_rollover_date_on(Date::Utility->new($weekday));
    my $date_start  = $rollover->minus_time_interval('59m59s');
    my $valid_start = $rollover->minus_time_interval('1h1s');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $valid_start,
        }) for qw(frxAUDUSD frxUSDHKD);
    $bet_params->{underlying}   = 'frxAUDUSD';
    $bet_params->{duration}     = '1d';
    $bet_params->{barrier}      = '110';
    $bet_params->{bet_type}     = 'CALL';
    $bet_params->{date_start}   = $bet_params->{date_pricing} = $date_start;
    $bet_params->{current_tick} = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxAUDUSD',
        epoch      => $valid_start->epoch
    });
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'not valid to buy';
    $bet_params->{duration} = '3d';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{duration}   = '1d';
    $bet_params->{date_start} = $bet_params->{date_pricing} = $valid_start;
    $c                        = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{date_start} = $bet_params->{date_pricing} = $date_start;
    $bet_params->{barrier}    = 'S0P';
    $c                        = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';

    my $GMT_21 = $bet_params->{date_pricing}->truncate_to_day->plus_time_interval('21h');
    $bet_params->{date_pricing} = $bet_params->{date_start} = $GMT_21;
    $bet_params->{duration}     = '5h';
    $bet_params->{current_tick} = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxAUDUSD',
        epoch      => $GMT_21->epoch
    });
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{duration} = '4h59m59s';
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is_deeply(
        ($c->primary_validation_error)[0]->{message_to_client},
        ['Trading on forex contracts with duration less than 5 hours is not available from [_1] to [_2]', '21:00:00', '23:59:59'],
        'throws error'
    );
    is_deeply $c->primary_validation_error->{details}, {field => 'duration'}, 'error detials is not correct';

    my $GMT_23 = $bet_params->{date_pricing}->truncate_to_day->plus_time_interval('23h');
    $bet_params->{date_pricing} = $bet_params->{date_start} = $GMT_23;
    $bet_params->{current_tick} = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxAUDUSD',
        epoch      => $GMT_23->epoch
    });
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is_deeply(
        ($c->primary_validation_error)[0]->{message_to_client},
        ['Trading on forex contracts with duration less than 5 hours is not available from [_1] to [_2]', '21:00:00', '23:59:59'],
        'throws error'
    );
    is_deeply $c->primary_validation_error->{details}, {field => 'duration'}, 'error detials is not correct';

    $bet_params->{underlying} = 'R_100';
    $bet_params->{duration}   = '4h59m59s';
    $c                        = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for random';
};

subtest 'date_expiry blackouts' => sub {
    note('Testing date_expiry blackouts for OTC_HSI');
    my $hsi               = create_underlying('OTC_HSI');
    my $new_week          = $weekday->plus_time_interval('7d');
    my $hsi_close         = $trading_calendar->closing_on($hsi->exchange, $new_week);
    my $hour_before_close = $hsi_close->minus_time_interval('1h');
    my $hsi_weekday_tick  = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'OTC_HSI',
        epoch      => $hour_before_close->epoch,
        quote      => 7195,
    });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'OTC_HSI',
            recorded_date => $hour_before_close
        });
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => 'OTC_HSI',
        date_start   => $hour_before_close,
        date_pricing => $hour_before_close,
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10,
        duration     => '58m59s',
        current_tick => $hsi_weekday_tick,
    };
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{duration} = '59m1s';
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is_deeply(($c->primary_validation_error)[0]->{message_to_client}, ['Contract may not expire between [_1] and [_2].', '07:59:00', '08:00:00']);
    is_deeply $c->primary_validation_error->{details}, {field => 'duration'}, 'error detials is not correct';

    my $usdjpy       = create_underlying('frxUSDJPY');
    my $usdjpy_close = $trading_calendar->closing_on($usdjpy->exchange, $new_week);
    my $pricing_date = $usdjpy_close->minus_time_interval('6h');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $pricing_date,
        }) for qw(frxAUDUSD frxUSDHKD);
    my $usdjpy_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxAUDUSD',
        epoch      => $pricing_date->epoch,
    });
    $bet_params->{date_pricing} = $bet_params->{date_start} = $pricing_date;
    $bet_params->{duration}     = '5h59m1s';
    $bet_params->{underlying}   = 'frxAUDUSD';
    $bet_params->{current_tick} = $usdjpy_tick;
    $c                          = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest 'date expiry blackout - year end holidays for equity' => sub {
    my $hsi        = create_underlying('OTC_HSI');
    my $year_end   = Date::Utility->new('2016-12-30');
    my $date_start = $trading_calendar->opening_on($hsi->exchange, $year_end)->plus_time_interval('15m');
    my $tick       = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'OTC_HSI',
        epoch      => $date_start->epoch,
        quote      => 7195,
    });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'OTC_HSI',
            recorded_date => $date_start
        });
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => 'OTC_HSI',
        date_start   => $date_start,
        date_pricing => $date_start,
        barrier      => 7205,
        currency     => 'USD',
        payout       => 10,
        duration     => '5d',
        current_tick => $tick,
    };
    my $c = produce_contract($bet_params);
    ok !$c->is_atm_bet,      'not ATM contract';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is_deeply(($c->primary_validation_error)[0]->{message_to_client}, ['Contract may not expire between [_1] and [_2].', '2016-12-30', '2017-01-05']);
    is_deeply $c->primary_validation_error->{details}, {field => 'duration'}, 'error detials is not correct';
    $bet_params->{barrier} = 'S0P';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for ATM';
    $bet_params->{barrier}  = 7205;
    $bet_params->{duration} = '7d';
    $c                      = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for non ATM past holiday blackout period';
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $date_start
        }) for qw(frxAUDUSD frxUSDHKD);
    $bet_params->{underlying} = 'frxAUDUSD';
    $bet_params->{duration}   = '5d';
    $bet_params->{barrier}    = 'S0P';
    $c                        = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for Forex during holiday blackout period';
};

subtest 'market_risk blackouts' => sub {
    note('Testing inefficient periods for frxXAUUSD');
    my $inefficient_period = $weekday->plus_time_interval('20h59m59s');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => 'XAU',
            recorded_date => $inefficient_period->minus_time_interval('1h')});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'frxXAUUSD',
            recorded_date => $inefficient_period->minus_time_interval('1h')});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $inefficient_period->minus_time_interval('1h'),
        }) for qw(frxXAUUSD);
    my $xauusd_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxXAUUSD',
        epoch      => $inefficient_period->minus_time_interval('1h')->epoch,
    });
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => 'frxXAUUSD',
        date_start   => $inefficient_period->minus_time_interval('1h'),
        date_pricing => $inefficient_period->minus_time_interval('1h'),
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10,
        duration     => '59m59s',
        current_tick => $xauusd_tick,
        pricing_vol  => 0.1,
    };
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{date_start} = $bet_params->{date_pricing} = $inefficient_period;
    $bet_params->{duration}   = '15m';
    $xauusd_tick              = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxXAUUSD',
        epoch      => $inefficient_period->epoch,
    });
    $bet_params->{current_tick} = $xauusd_tick;
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is_deeply(($c->primary_validation_error)[0]->{message_to_client}, ['Trading is not available from [_1] to [_2].', '21:00:00', '23:59:59']);
    is_deeply $c->primary_validation_error->{details}, {field => 'duration'}, 'error detials is not correct';
};

subtest 'expiry daily contract on indices during christmas/new year period' => sub {
    note 'holiday period for equity starts on day-345 to day-5 of the next year';
    my $holiday_start = Date::Utility->new('2019-01-01')->plus_time_interval('345d');
    my $hsi           = create_underlying('OTC_HSI');
    my $hsi_open      = $trading_calendar->opening_on($hsi->exchange, $holiday_start)->plus_time_interval('15m');
    my $tick          = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'OTC_HSI',
        epoch      => $hsi_open->epoch,
        quote      => 7195,
    });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'OTC_HSI',
            recorded_date => $hsi_open
        });
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => 'OTC_HSI',
        date_start   => $hsi_open,
        date_pricing => $hsi_open,
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10,
        duration     => '5d',
        current_tick => $tick,
    };
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';

    $bet_params->{barrier} = '7199';
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message_to_client->[0], 'Contract may not expire between [_1] and [_2].';
    is $c->primary_validation_error->message_to_client->[1], '2019-12-12';
    is $c->primary_validation_error->message_to_client->[2], '2020-01-05';

    $bet_params->{date_pricing} = $hsi_open->plus_time_interval('1h');
    $bet_params->{entry_tick}   = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'OTC_HSI',
        epoch      => $hsi_open->epoch + 1,
        quote      => 7196,
    });
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_sell, 'invalid to sell';
    is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.';

    $bet_params->{date_pricing} = $hsi_open;
    delete $bet_params->{entry_tick};
    $bet_params->{underlying} = 'R_100';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest 'end of day two minute blackout' => sub {
    # fixed time to avoid weekend
    my $now        = Date::Utility->new('8-04-2020');
    my $underlying = create_underlying('R_100');
    my $close      = $trading_calendar->closing_on($underlying->exchange, $now);
    my $start      = $close->minus_time_interval('2m');
    my $tick       = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $start->epoch,
        quote      => 7195,
    });
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => $underlying,
        date_start   => $start,
        date_pricing => $start,
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10,
        duration     => '5d',
        current_tick => $tick,
    };
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid for synthetic';

    $bet_params->{underlying} = create_underlying('frxUSDJPY');
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'invalid for forex';
    is $c->primary_validation_error->message_to_client->[0], 'Trading is not available from [_1] to [_2].';
    is $c->primary_validation_error->message_to_client->[1], '23:57:59';
    is $c->primary_validation_error->message_to_client->[2], '23:59:59';
};

subtest 'rollover blackout' => sub {
    my $start      = Date::Utility->new('2020-07-15 20:45:00');
    my $entry_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $start->epoch,
        quote      => 7195,
    });
    my $current_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $start->plus_time_interval('14m')->epoch,
        quote      => 7195,
    });
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        date_start   => $start,
        date_pricing => $start->plus_time_interval('14m'),
        barrier      => 'S10P',
        currency     => 'USD',
        payout       => 10,
        duration     => '5d',
        current_tick => $current_tick,
        entry_tick   => $entry_tick,
    };
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_sell, 'valid to sell';

    $bet_params->{date_pricing} = $start->plus_time_interval('15m');
    $bet_params->{current_tick} = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $start->plus_time_interval('15m')->epoch,
        quote      => 7195,
    });
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_sell, 'not valid to sell';
    is $c->primary_validation_error->message_to_client->[0], 'Resale of this contract is not offered.',                      'message to client';
    is $c->primary_validation_error->message,                'resale not available for non-atm from rollover to end of day', 'message';

    $bet_params->{underlying} = 'R_100';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_sell, 'valid to sell';
};

done_testing();
