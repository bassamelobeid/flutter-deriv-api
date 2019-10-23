#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::Warnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Date::Utility;

use BOM::Config::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Test::MockModule;
use BOM::Config::Chronicle;
use Quant::Framework;

my $weekend             = Date::Utility->new('2016-03-26');
my $weekday             = Date::Utility->new('2016-03-29');
my $usdjpy_weekend_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxAUDUSD',
    epoch      => $weekend->epoch
});
my $usdjpy_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxAUDUSD',
    epoch      => $weekday->epoch
});

for my $date ($weekend, $weekday) {
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $date
        }) for qw(USD AUD HKD AUD-USD);
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'HSI',
            recorded_date => $date
        });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => $_,
            recorded_date => $date
        }) for qw(RDBULL R_100);

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $date
        }) for qw(frxAUDUSD frxAUDUSD frxUSDHKD);
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'HSI',
            recorded_date => $date
        });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'correlation_matrix',
        {
            recorded_date => $date,
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
}

subtest 'trading hours' => sub {
    my $args = {
        bet_type     => 'CALL',
        underlying   => 'frxAUDUSD',
        barrier      => 'S0P',
        date_start   => $weekday,
        date_pricing => $weekday,
        duration     => '6h',
        currency     => 'USD',
        payout       => 10,
        current_tick => $usdjpy_weekday_tick,
    };

    my $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';
    $args->{date_start} = $args->{date_pricing} = $weekend;
    $args->{current_tick} = $usdjpy_weekend_tick;
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is_deeply(($c->primary_validation_error)[0]->{message_to_client},
        ['This market is presently closed. Try out the Synthetic Indices which are always open.']);
    is_deeply $c->primary_validation_error->{details}, {field => 'symbol'}, 'error detials is not correct';

    my $hsi_open         = $weekday->plus_time_interval('1h30m');
    my $hsi_time         = $hsi_open->plus_time_interval('11m');
    my $hsi_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $hsi_time->epoch,
        quote      => 7150
    });
    $args->{underlying}   = 'HSI';
    $args->{date_start}   = $args->{date_pricing} = $hsi_time;
    $args->{current_tick} = $hsi_weekday_tick;
    $args->{duration}     = '1h';
    $c                    = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';
    $args->{date_start} = $args->{date_pricing} = $hsi_time->minus_time_interval('22m');
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is_deeply(($c->primary_validation_error)[0]->{message_to_client},
        ['This market is presently closed. Try out the Synthetic Indices which are always open.']);
    is_deeply $c->primary_validation_error->{details}, {field => 'symbol'}, 'error detials is not correct';

    # for forward starting
    $args->{date_pricing} = $hsi_open->minus_time_interval('20m');
    $args->{date_start}   = $hsi_open->minus_time_interval('10m');
    $c                    = produce_contract($args);
    ok $c->is_forward_starting, 'forward starting';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is_deeply(($c->primary_validation_error)[0]->{message_to_client},
        ['The market must be open at the start time. Try out the Synthetic Indices which are always open.']);
    is_deeply $c->primary_validation_error->{details}, {field => 'date_start'}, 'error detials is not correct';
    $args->{date_start} = $hsi_open->plus_time_interval('11m');
    $c = produce_contract($args);
    ok $c->is_forward_starting, 'forward starting';
    ok $c->is_valid_to_buy,     'valid to buy';

    my $valid_start = $hsi_open->plus_time_interval('2h');
    $args->{date_start} = $args->{date_pricing} = $valid_start;
    $args->{duration}   = '1h';
    $hsi_weekday_tick   = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $valid_start->epoch,
        quote      => 7150
    });
    $args->{current_tick} = $hsi_weekday_tick;
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is_deeply(($c->primary_validation_error)[0]->{message_to_client}, ['Contract must expire during trading hours.']);
    is_deeply $c->primary_validation_error->{details}, {field => 'duration'}, 'error detials is not correct';
};

subtest 'invalid expiry time for multiday contracts' => sub {
    my $now       = Date::Utility->new;
    my $fake_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch
    });
    my $bet_params = {
        underlying   => 'R_100',
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        date_pricing => $now,
        barrier      => 'S0P',
        current_tick => $fake_tick,
        date_pricing => $now,
        date_start   => $now,
        date_expiry  => $now->plus_time_interval('1d1s'),
    };
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message}, qr/daily expiry must expire at close/, 'throws error');
    is_deeply $c->primary_validation_error->{details}, {field => 'date_expiry'}, 'error detials is not correct';
    $bet_params->{date_expiry} = $now->truncate_to_day->plus_time_interval('1d23h59m59s');
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest 'intraday must be same day' => sub {
    my $eod      = $weekday->plus_time_interval('22h');
    my $eod_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'RDBULL',
        epoch      => $eod->epoch
    });
    my $bet_params = {
        underlying   => 'RDBULL',
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        date_pricing => $eod,
        date_start   => $eod,
        duration     => '59m59s',
        barrier      => 'S0P',
        current_tick => $eod_tick,
    };
    $bet_params->{disable_trading_at_quiet_period} = 0;
    my $c = produce_contract($bet_params);
    ok $c->underlying->intradays_must_be_same_day, 'intraday must be same day';
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{duration} = '2h1s';
    $c = produce_contract($bet_params);
    ok $c->underlying->intradays_must_be_same_day, 'intraday must be same day';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message}, qr/Intraday duration must expire on same day/, 'throws error');
    is_deeply $c->primary_validation_error->{details}, {field => 'duration'}, 'error detials is not correct';

    $bet_params->{underlying} = 'R_100';
    $c = produce_contract($bet_params);
    ok !$c->underlying->intradays_must_be_same_day, 'intraday can cross day';
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest 'too many holiday for multiday indices contracts' => sub {
    my $hsi              = create_underlying('HSI');
    my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader);
    my $monday_open      = $hsi->calendar->opening_on($hsi->exchange, Date::Utility->new('2016-04-04'))->plus_time_interval('15m');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxUSDHKD',
            recorded_date => $monday_open
        });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'HSI',
            recorded_date => $monday_open
        });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'holiday',
        {
            recorded_date => $monday_open,
            calendar      => {
                $monday_open->plus_time_interval('4d')->date => {
                    'Test Holiday' => ['HKSE'],
                },
                $monday_open->plus_time_interval('2d')->date => {
                    'Test Holiday' => ['HKSE'],
                },
                $monday_open->plus_time_interval('1d')->date => {
                    'Test Holiday 2' => ['HKSE'],
                },
            },
        });
    my $hsi_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $monday_open->epoch,
        quote      => 7150
    });
    my $bet_params = {
        underlying   => 'HSI',
        bet_type     => 'CALL',
        barrier      => 'S10P',
        payout       => 100,
        date_start   => $monday_open,
        date_pricing => $monday_open,
        duration     => '7d',
        currency     => 'USD',
        current_tick => $hsi_tick,
    };
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->message, qr/Not enough trading days for calendar days/, 'throws error');
    is_deeply $c->primary_validation_error->{details}, {field => 'date_expiry'}, 'error detials is not correct';
    $bet_params->{barrier} = 'S0P';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
};
