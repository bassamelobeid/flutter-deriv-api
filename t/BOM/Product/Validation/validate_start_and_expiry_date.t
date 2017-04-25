use strict;
use warnings;

use Test::More tests => 4;
use Test::MockModule;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Date::Utility;

use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

initialize_realtime_ticks_db;

my $weekday             = Date::Utility->new('2016-03-29');
my $usdjpy_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxAUDUSD',
    epoch      => $weekday->epoch
});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $weekday
    }) for qw(USD JPY HKD AUD-USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'HSI',
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
        symbol        => 'HSI',
        recorded_date => $weekday
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'correlation_matrix',
    {
        recorded_date => $weekday,
        symbol        => 'indices',
        correlations  => {
            'HSI' => {
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
    ok $c->is_valid_to_buy, 'valid to buy';

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
    ok $c->is_valid_to_buy, 'valid to buy';

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
    ok $c->is_valid_to_buy, 'valid to buy at one second before 30-Mar-16 close';

    my $friday_close                     = Date::Utility->new('2016-04-01 21:00:00');
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
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/Trading is not available from 20:55:00 to 21:00:00/, 'throws error');

    note('Testing date_start blackouts for frxAUDUSD on Monday ');

    $bet_params->{date_start} = Date::Utility->new('2016-04-04');
    $bet_params->{duration}   = '10m';
    $c                        = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy at 10 mins forward starting of forex on Monday morning';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/Trading is not available from 00:00:00 to 00:10:00/, 'throws error');

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

    note('Testing date_start blackouts for HSI');
    my $hsi_open         = create_underlying('HSI')->calendar->opening_on($weekday);
    my $hsi_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $hsi_open->epoch + 600,
        quote      => 7195,
    });
    $bet_params->{underlying}   = 'HSI';
    $bet_params->{current_tick} = $hsi_weekday_tick;
    $bet_params->{date_start}   = $bet_params->{date_pricing} = $hsi_open->epoch + 599;
    $bet_params->{duration}     = '1h';
    $c                          = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/from 01:30:00 to 01:40:00/, 'throws error');
    $bet_params->{date_pricing} = $hsi_open->plus_time_interval('1m');
    $bet_params->{date_start}   = $hsi_open->epoch + 600;
    $bet_params->{duration}     = '1h';
    $c                          = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy forward starting contract on first 1 minute of opening';
    my $hsi_close = create_underlying('HSI')->calendar->closing_on($weekday);
    $hsi_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $hsi_close->epoch - 900,
        quote      => 7195,
    });
    $bet_params->{date_start} = $bet_params->{date_pricing} = $hsi_close->epoch - 900;
    $bet_params->{duration} = '15m';
    $bet_params->{current_tick} = $hsi_weekday_tick;
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/from 07:25:00 to 07:40:00/, 'throws error');

    note('Multiday contract on HSI');
    my $new_day           = $weekday->plus_time_interval('1d');
    my $hour_before_close = create_underlying('HSI')->calendar->closing_on($new_day)->minus_time_interval('1h');
    $hsi_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $hour_before_close->epoch,
        quote      => 7195,
    });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'HSI',
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
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/from 06:40:00 to 07:40:00/, 'throws error');
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
    my $rollover    = Quant::Framework::VolSurface::Utils->new->NY1700_rollover_date_on(Date::Utility->new($weekday));
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
    $bet_params->{duration} = '5h';
    $bet_params->{current_tick} = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxAUDUSD',
        epoch      => $GMT_21->epoch
    });
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{duration} = '4h59m59s';
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/Trading on forex contracts with duration less than 5 hours is not available from 21:00:00 to 23:00:00/, 'throws error');
    $bet_params->{underlying} = 'R_100';
    $bet_params->{duration} = '4h59m59s';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for random';
    $bet_params->{underlying} = 'frxAUDUSD';
    $bet_params->{barrier} = 76.8999;
    $bet_params->{landing_company} = 'japan';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid for japan';
    delete $bet_params->{landing_company};
};

subtest 'date_expiry blackouts' => sub {
    note('Testing date_expiry blackouts for HSI');
    my $new_week          = $weekday->plus_time_interval('7d');
    my $hsi_close         = create_underlying('HSI')->calendar->closing_on($new_week);
    my $hour_before_close = $hsi_close->minus_time_interval('1h');
    my $hsi_weekday_tick  = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $hour_before_close->epoch,
        quote      => 7195,
    });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'HSI',
            recorded_date => $hour_before_close
        });
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => 'HSI',
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
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/between 07:39:00 and 07:40:00/, 'throws error');

    my $usdjpy_close = create_underlying('frxAUDUSD')->calendar->closing_on($new_week);
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
    my $year_end   = Date::Utility->new('2016-12-30');
    my $date_start = create_underlying('HSI')->calendar->opening_on($year_end)->plus_time_interval('15m');
    my $tick       = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $date_start->epoch,
        quote      => 7195,
    });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'HSI',
            recorded_date => $date_start
        });
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => 'HSI',
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
    like($c->primary_validation_error->message_to_client, qr/not expire between 2016-12-30 and 2017-01-05/, 'throws error');
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
        bet_type                  => 'CALL',
        underlying                => 'frxXAUUSD',
        date_start                => $inefficient_period->minus_time_interval('1h'),
        date_pricing              => $inefficient_period->minus_time_interval('1h'),
        barrier                   => 'S0P',
        currency                  => 'USD',
        payout                    => 10,
        duration                  => '59m59s',
        current_tick              => $xauusd_tick,
        pricing_vol               => 0.1,
        news_adjusted_pricing_vol => 0.1,
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
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/from 21:00:00 to 23:59:59/, 'throws error');
};
