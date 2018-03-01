#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Format::Util::Numbers qw(roundnear);
use Date::Utility;
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
        underlying => 'R_100',
        epoch      => $pair->[0],
        quote      => $pair->[1],
    });
}

my $args = {
    bet_type     => 'LBFLOATCALL',
    underlying   => 'R_100',
    date_start   => $now,
    date_pricing => $now,
    duration     => '1h',
    currency     => 'USD',
    multiplier   => 1,
};

subtest 'lbfloatcall' => sub {

    $args->{bet_type}     = 'LBFLOATCALL';
    $args->{date_pricing} = $now;
    my $c = produce_contract($args);
    isa_ok $c, 'BOM::Product::Contract::Lbfloatcall';
    is $c->payouttime,   'end';
    is $c->code,         'LBFLOATCALL';
    is $c->pricing_code, 'LBFLOATCALL';

    ok !$c->is_path_dependent;
    isa_ok $c->pricing_engine, 'Pricing::Engine::Lookback';

    $args->{duration} = '1d';
    $args->{barrier}  = 100.030;
    $c                = produce_contract($args);
    isa_ok $c->pricing_engine, 'Pricing::Engine::Lookback';

    is $c->expiry_type, 'daily';
    ok !$c->is_expired, 'not expired';

    $args->{date_pricing} = $args->{date_start}->epoch + 31;
    $c = produce_contract($args);
    ok !$c->is_expired, 'expired';

    $args->{barrier}            = 100.050;
    $args->{date_pricing}       = $now->truncate_to_day->plus_time_interval('2d');
    $args->{exit_tick}          = $close_tick;                                       # INJECT OHLC since cannot find it in the test DB.
    $args->{is_valid_exit_tick} = 1;
    $c                          = produce_contract($args);
    cmp_ok $c->date_pricing->epoch, '>', $c->date_expiry->epoch, 'after expiry';
    ok $c->is_expired, 'expired';
};

subtest 'lbfloatput' => sub {

    $args->{bet_type}     = 'LBFLOATPUT';
    $args->{date_pricing} = $now;
    my $c = produce_contract($args);
    isa_ok $c, 'BOM::Product::Contract::Lbfloatput';
    is $c->payouttime,   'end';
    is $c->code,         'LBFLOATPUT';
    is $c->pricing_code, 'LBFLOATPUT';

    ok !$c->is_path_dependent;
    isa_ok $c->pricing_engine, 'Pricing::Engine::Lookback';

    $args->{duration} = '1d';
    $args->{barrier}  = 100.030;
    $c                = produce_contract($args);
    isa_ok $c->pricing_engine, 'Pricing::Engine::Lookback';

    is $c->expiry_type, 'daily';
    ok !$c->is_expired, 'not expired';

    $args->{date_pricing} = $args->{date_start}->epoch + 31;
    $c = produce_contract($args);
    ok !$c->is_expired, 'expired';

    $args->{barrier}            = 100.050;
    $args->{date_pricing}       = $now->truncate_to_day->plus_time_interval('2d');
    $args->{exit_tick}          = $close_tick;                                       # INJECT OHLC since cannot find it in the test DB.
    $args->{is_valid_exit_tick} = 1;
    $c                          = produce_contract($args);
    cmp_ok $c->date_pricing->epoch, '>', $c->date_expiry->epoch, 'after expiry';
    ok $c->is_expired, 'expired';
};

subtest 'lbhighlow' => sub {

    $args->{bet_type}     = 'LBHIGHLOW';
    $args->{date_pricing} = $now;
    my $c = produce_contract($args);
    isa_ok $c, 'BOM::Product::Contract::Lbhighlow';
    is $c->payouttime,   'end';
    is $c->code,         'LBHIGHLOW';
    is $c->pricing_code, 'LBHIGHLOW';

    ok !$c->is_path_dependent;
    isa_ok $c->pricing_engine, 'Pricing::Engine::Lookback';

    $args->{duration} = '1d';
    $args->{barrier}  = 100.030;
    $c                = produce_contract($args);
    isa_ok $c->pricing_engine, 'Pricing::Engine::Lookback';

    is $c->expiry_type, 'daily';
    ok !$c->is_expired, 'not expired';

    $args->{date_pricing} = $args->{date_start}->epoch + 31;
    $c = produce_contract($args);
    ok !$c->is_expired, 'expired';

    $args->{barrier}            = 100.050;
    $args->{date_pricing}       = $now->truncate_to_day->plus_time_interval('2d');
    $args->{exit_tick}          = $close_tick;                                       # INJECT OHLC since cannot find it in the test DB.
    $args->{is_valid_exit_tick} = 1;
    $c                          = produce_contract($args);
    cmp_ok $c->date_pricing->epoch, '>', $c->date_expiry->epoch, 'after expiry';
    ok $c->is_expired, 'expired';
};
