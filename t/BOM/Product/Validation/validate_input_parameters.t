#!/etc/rmg/bin/perl

use Test::More;
use Test::Exception;
use Test::Warnings;
use Test::Fatal;

use Date::Utility;
use Scalar::Util qw(blessed);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Config::Runtime;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Try::Tiny;

use Test::MockModule;
use Postgres::FeedDB::Spot::Tick;
use Quant::Framework::VolSurface::Delta;

my $now = Date::Utility->new('2016-03-18 01:00:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD UST);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'R_100',
        recorded_date => $now
    });

my $fake_tick = Postgres::FeedDB::Spot::Tick->new({
    underlying => 'R_100',
    epoch      => $now->epoch,
    quote      => 100,
});

my $bet_params = {
    underlying   => 'R_100',
    bet_type     => 'CALL',
    currency     => 'USD',
    payout       => 100,
    date_pricing => $now,
    barrier      => 'S0P',
    current_tick => $fake_tick,
};

subtest 'invalid start and expiry time' => sub {
    $bet_params->{date_start} = $bet_params->{date_expiry} = $now;
    my $exception = try {
        produce_contract($bet_params);
    }
    catch {
        blessed($_);
        $_;
    };
    is $exception->error_code, 'SameExpiryStartTime', 'throws exception if start time == expiry time';
    $bet_params->{date_start}  = $now;
    $bet_params->{date_expiry} = $now->epoch - 1;
    $exception                 = try {
        produce_contract($bet_params);
    }
    catch {
        blessed($_);
        $_;
    };
    is $exception->error_code, 'PastExpiryTime', 'throws exception if start time > expiry time';
    $bet_params->{date_start}   = $now;
    $bet_params->{date_pricing} = $now->epoch + 1;
    $bet_params->{date_expiry}  = $now->epoch + 20 * 60;
    $bet_params->{entry_tick}   = $fake_tick;
    $c                          = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->{message}, qr/starts in the past/, 'start < now');
    is $c->primary_validation_error->{details}->{field}, 'date_start', 'error detials is not correct';
    $bet_params->{for_sale} = 1;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy if it is a recreated contract';
    $bet_params->{date_start}   = $now->epoch + 1;
    $bet_params->{date_pricing} = $now;
    $bet_params->{bet_type}     = 'ONETOUCH';
    $bet_params->{barrier}      = 110;
    $c                          = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(
        $c->primary_validation_error->{message},
        qr/Forward time for non-forward-starting contract type/,
        'start > now for non forward starting contract type'
    );
    is $c->primary_validation_error->{details}->{field}, 'date_start', 'error detials is not correct';
    $bet_params->{bet_type} = 'CALL';
    $bet_params->{barrier}  = 'S0P';
    $c                      = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for CALL at a forward start time';
    delete $bet_params->{for_sale};
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->{message}, qr/forward-starting blackout/, 'forward starting blackout');
    is $c->primary_validation_error->{details}->{field}, 'date_start', 'error detials is not correct';
    $bet_params->{date_start} = $now->epoch + 5 * 60;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
};

$fake_tick = Postgres::FeedDB::Spot::Tick->new({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch,
    quote      => 100,
});

my $bet_params2 = {
    underlying   => 'frxUSDJPY',
    bet_type     => 'CALL',
    currency     => 'USD',
    payout       => 100,
    date_start   => $now,
    date_pricing => $now,
    duration     => '4d',
    barrier      => '0',
    current_tick => $fake_tick,
};

subtest 'absolute barrier for a non-intraday contract' => sub {
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $now,
            rates         => {
                1   => 0,
                100 => 0,
                365 => 0
            },
        }) for qw(USD JPY JPY-USD);

    my $forex = create_underlying('frxUSDJPY');

    Quant::Framework::Utils::Test::create_doc(
        'volsurface_delta',
        {
            underlying       => $forex,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
            recorded_date    => $now,
            surface_data     => {
                1 => {
                    smile => {
                        25 => 0.19,
                        50 => 0.15,
                        75 => 0.23,
                    },
                    vol_spread => {
                        50 => 0.02,
                    },
                },
                30 => {
                    smile => {
                        25 => 0.24,
                        50 => 0.18,
                        75 => 0.29,
                    },
                    vol_spread => {
                        50 => 0.02,
                    },
                },
            }});

    my $c = produce_contract($bet_params2);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->{message}, qr/Absolute barrier cannot be zero/, 'Absolute barrier cannot be zero');
    is $c->primary_validation_error->{details}->{field}, 'barrier', 'error detials is not correct';

    $bet_params2->{barrier} = 101;
    $c = produce_contract($bet_params2);
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest 'invalid barrier for tick expiry' => sub {
    my $bet_params = {
        date_start   => $now,
        date_pricing => $now,
        underlying   => 'R_100',
        bet_type     => 'CALL',
        duration     => '5t',
        barrier      => 100,
        currency     => 'USD',
        payout       => 10,
        current_tick => $fake_tick,
    };
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{barrier} = 'S10P';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{barrier}  = 100;
    $bet_params->{bet_type} = 'ASIANU';
    $c                      = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for asian';
    delete $bet_params->{date_pricing};
    $bet_params->{entry_tick} = $fake_tick;
    $bet_params->{exit_tick}  = $fake_tick;
    $c                        = produce_contract($bet_params);
    ok $c->is_valid_to_sell, 'valid to sell for asian';

    $bet_params->{underlying}   = 'frxUSDJPY';
    $bet_params->{barrier}      = 100;
    $bet_params->{date_pricing} = $now;
    $bet_params->{date_start}   = $now;
    delete $bet_params->{exit_tick};
    $c = produce_contract($bet_params);
    ok $c->tick_expiry, 'tick expiry';
    ok !$c->is_valid_to_buy, 'invalid to buy for frxUSDJPY';
    like($c->primary_validation_error->{message}, qr/Intend to buy tick expiry contract/, 'tick expiry barrier check');
    is $c->primary_validation_error->{details}->{field}, 'barrier', 'error detials is not correct';
};

subtest 'invalid barrier type' => sub {
    my $bet_params = {
        date_start   => $now,
        date_pricing => $now,
        underlying   => 'R_100',
        bet_type     => 'CALL',
        duration     => '1d',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10,
        current_tick => $fake_tick,
    };
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid multi-day ATM contract with relative barrier.';
    $bet_params->{barrier} = 'S10P';
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'invalid multi-day non ATM contract with relative barrier.';
    like(
        $c->primary_validation_error->{message},
        qr/barrier should be absolute for multi-day contracts/,
        'multi-day non ATM barrier must be absolute'
    );
    is $c->primary_validation_error->{details}->{field}, 'barrier', 'error detials is not correct';
    $bet_params->{duration} = '1h';
    $bet_params->{barrier}  = 100;
    $c                      = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid intraday non ATM contract with absolute barrier.';
};

subtest 'invalid payout currency' => sub {
    my $bet_params = {
        date_start   => $now,
        date_pricing => $now,
        underlying   => 'R_100',
        bet_type     => 'CALL',
        duration     => '1d',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10,
        current_tick => $fake_tick,
    };
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid multi-day ATM contract with relative barrier.';
    ok !$c->invalid_user_input;
    $bet_params->{currency} = 'BDT';
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    ok $c->invalid_user_input, 'invalid input set to true';
    like($c->primary_validation_error->{message}, qr/payout currency not supported/, 'payout currency not supported');
    is $c->primary_validation_error->{details}->{field}, 'currency', 'error detials is not correct';
};

subtest 'stable crypto as payout currency' => sub {
    my $now        = Date::Utility->new($fake_tick->epoch);
    my $bet_params = {
        date_start   => $now,
        date_pricing => $now,
        underlying   => 'frxUSDJPY',
        bet_type     => 'CALL',
        duration     => '3d',
        barrier      => 'S0P',
        currency     => 'UST',
        payout       => 10,
        current_tick => $fake_tick,
    };
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid multi-day ATM contract with relative barrier.';
    lives_ok { $c->ask_price } 'ask price without exception';
};

subtest 'missing trading_period_start' => sub {
    my $now        = Date::Utility->new($fake_tick->epoch);
    my $bet_params = {
        bet_type             => 'CALLE',
        date_start           => $now,
        date_pricing         => $now,
        duration             => '20m',
        barrier              => 'S20P',
        underlying           => 'frxUSDJPY',
        currency             => 'USD',
        payout               => 10,
        product_type         => 'multi_barrier',
        trading_period_start => $now->epoch,
        current_tick         => $fake_tick,
    };

    my $c = produce_contract($bet_params);
    lives_ok { $c->ask_price } 'create a multi_barrier contract without exception';

    delete $bet_params->{trading_period_start};
    try {
        $c = produce_contract($bet_params);
    }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->error_code, "MissingTradingPeriodStart", 'error code is MissingTradingPeriodStart';
    };

};

done_testing();
