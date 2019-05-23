#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Warnings;
use Test::Exception;
use Date::Utility;
use Format::Util::Numbers qw/roundcommon/;

use Try::Tiny;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract);

initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-Mar-2015');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        recorded_date => $now,
        symbol        => $_,
    }) for qw( USD JPY JPY-USD );

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });

my @ticks_to_add = (
    [$now->epoch        => 100],
    [$now->epoch + 1    => 100],
    [$now->epoch + 2    => 100.020],
    [$now->epoch + 30   => 100.030],
    [$now->epoch + 3600 => 100.020],
    [$now->epoch + 3601 => 100]);

my $close_tick;

foreach my $pair (@ticks_to_add) {
    # We just want the last one to INJECT below
    # OHLC test DB does not work as expected.
    $close_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $pair->[0],
        quote      => $pair->[1],
    });
}

my $args = {
    bet_type     => 'ONETOUCH',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    date_pricing => $now,
    duration     => '1h',
    currency     => 'USD',
    payout       => 10,
    barrier      => 'S20P',
};

subtest 'touch' => sub {
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Onetouch';
        is $c->payouttime,   'hit';
        is $c->code,         'ONETOUCH';
        is $c->pricing_code, 'ONETOUCH';

        is $c->ask_price, 9.37;
        is roundcommon(0.001, $c->pricing_vol), 0.201;

        is $c->sentiment, 'high_vol';
        ok $c->is_path_dependent;
        is_deeply $c->supported_expiries, ['intraday', 'daily', 'tick'];
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated';
        isa_ok $c->greek_engine,   'BOM::Product::Pricing::Greeks::BlackScholes';
    }
    'generic';

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('1s');
        my $c = produce_contract($args);
        ok $c->entry_tick;
        cmp_ok $c->entry_tick->quote, '==', 100.000, 'correct entry tick';
        ok $c->barrier;
        cmp_ok $c->barrier->as_absolute, '==', 100.020, 'correct barrier';
        ok !$c->is_expired, 'not expired';
        cmp_ok $c->value, '==', 0.00, 'zero payout';
        $args->{date_pricing} = $now->plus_time_interval('2s');
        $c = produce_contract($args);
        cmp_ok $c->date_pricing->epoch, '<', $c->date_expiry->epoch, 'date pricing is before expiry';
        ok $c->is_expired, 'expired';
        cmp_ok $c->hit_tick->quote, '==', 100.020, 'correct hit tick';
        cmp_ok $c->value, '==', $c->payout, 'full payout';
        $args->{barrier}      = 'S40P';
        $args->{date_pricing} = $now->plus_time_interval('1h1s');
        $c                    = produce_contract($args);
        cmp_ok $c->date_pricing->epoch, '>', $c->date_expiry->epoch, 'after expiry';
        ok $c->is_expired, 'expired';
        ok !$c->hit_tick, 'hit tick is undef';
        cmp_ok $c->value, '==', 0.00, 'zero payout';
    }
    'expiry checks';

    lives_ok {
        my $args_err = {
            bet_type     => 'ONETOUCH',
            underlying   => 'frxUSDJPY',
            date_start   => $now,
            date_pricing => $now->plus_time_interval('1m'),
            duration     => '1h',
            currency     => 'USD',
            amount       => 10,
            amount_type  => 'stake',
            barrier      => '0',
        };

        try { produce_contract($args_err) }
        catch {
            isa_ok $_, 'BOM::Product::Exception';
            is $_->message_to_client->[0], 'Barrier cannot be zero.', 'throws exception when absolute barrier is zero';
        };
    }
    'zero barrier error';
};

subtest 'notouch' => sub {
    lives_ok {
        $args->{bet_type}     = 'NOTOUCH';
        $args->{date_pricing} = $now;
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Notouch';
        is $c->payouttime,   'end';
        is $c->code,         'NOTOUCH';
        is $c->pricing_code, 'NOTOUCH';
        is $c->sentiment,    'low_vol';
        ok $c->is_path_dependent;
        is_deeply $c->supported_expiries, ['intraday', 'daily', 'tick'];
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated';
        isa_ok $c->greek_engine,   'BOM::Product::Pricing::Greeks::BlackScholes';
    }
    'generic';

    lives_ok {
        $args->{duration} = '1d';
        $args->{barrier}  = 100.030;
        my $c = produce_contract($args);
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated';
        ok !$c->is_intraday, 'not intraday';
        is $c->expiry_type, 'daily';
        ok !$c->is_expired, 'not expired';
        cmp_ok $c->value, '==', 0.00, 'zero payout';
        $args->{date_pricing} = $args->{date_start}->epoch + 31;
        $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok $c->hit_tick,   'hit tick present';
        cmp_ok $c->hit_tick->quote, '==', 100.030, 'correct hit tick';
        cmp_ok $c->value, '==', 0.00, 'zero payout, cause it touched';
        $args->{barrier}            = 100.050;
        $args->{date_pricing}       = $now->truncate_to_day->plus_time_interval('2d');
        $args->{exit_tick}          = $close_tick;                                       # INJECT OHLC since cannot find it in the test DB.
        $args->{is_valid_exit_tick} = 1;
        $c                          = produce_contract($args);
        cmp_ok $c->date_pricing->epoch, '>', $c->date_expiry->epoch, 'after expiry';
        ok $c->is_expired, 'expired';
        ok !$c->hit_tick, 'no hit tick';
        cmp_ok $c->value, '==', $c->payout, 'full payout';
    }
    'expiry checks';
};
