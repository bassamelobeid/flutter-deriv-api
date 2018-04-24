#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Format::Util::Numbers qw(roundnear);
use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use Try::Tiny;

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
    amount_type  => 'multiplier',
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
    $c = produce_contract($args);
    isa_ok $c->pricing_engine, 'Pricing::Engine::Lookback';

    is $c->expiry_type, 'daily';
    ok !$c->is_expired, 'not expired';

    $args->{date_pricing} = $args->{date_start}->epoch + 31;
    $c = produce_contract($args);
    ok !$c->is_expired, 'expired';

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
    $c = produce_contract($args);
    isa_ok $c->pricing_engine, 'Pricing::Engine::Lookback';

    is $c->expiry_type, 'daily';
    ok !$c->is_expired, 'not expired';

    $args->{date_pricing} = $args->{date_start}->epoch + 31;
    $c = produce_contract($args);
    ok !$c->is_expired, 'expired';

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
    $c = produce_contract($args);
    isa_ok $c->pricing_engine, 'Pricing::Engine::Lookback';

    is $c->expiry_type, 'daily';
    ok !$c->is_expired, 'not expired';

    $args->{date_pricing} = $args->{date_start}->epoch + 31;
    $c = produce_contract($args);
    ok !$c->is_expired, 'expired';

    $args->{date_pricing}       = $now->truncate_to_day->plus_time_interval('2d');
    $args->{exit_tick}          = $close_tick;                                       # INJECT OHLC since cannot find it in the test DB.
    $args->{is_valid_exit_tick} = 1;
    $c                          = produce_contract($args);
    cmp_ok $c->date_pricing->epoch, '>', $c->date_expiry->epoch, 'after expiry';
    ok $c->is_expired, 'expired';
};

subtest 'invalid amount_type' => sub {
    $args->{amount_type} = 'unkown';
    try {
        produce_contract($args);
    }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->error_code, 'WrongAmountTypeNonBinary', 'correct error code';
        is $_->message_to_client->[0], 'Basis has to be equal to multiplier for non-binary options.';
    };
};

subtest 'spot_min and spot_max checks' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;
    my $now  = Date::Utility->new;
    my $args = {
        bet_type     => 'LBFLOATCALL',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        duration     => '1h',
        currency     => 'USD',
        multiplier   => 1,
        amount_type  => 'multiplier',
    };
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => 101,
        epoch      => $now->epoch,
    });
    my $c = produce_contract($args);
    note 'high/low are undefined because first tick of the contract is the next tick. Hence using pricing spot as min and max values';
    is $c->spot_min_max->{low},  101, 'spot_min is 101';
    is $c->spot_min_max->{high}, 101, 'spot_max is 101';

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            quote      => $_->[0],
            epoch      => $_->[1],
        }) for ([102, $now->epoch + 1], [103, $now->epoch + 2], [104, $now->epoch + 3]);

    $args->{date_pricing} = $now->epoch + 1;
    $c = produce_contract($args);
    note 'high/low is 102, which is the next tick';
    is $c->spot_min_max->{low},  102, 'spot_min is 102';
    is $c->spot_min_max->{high}, 102, 'spot_max is 102';

    $args->{date_pricing} = $now->epoch + 2;
    $c = produce_contract($args);
    note 'high is 103 and low is 102';
    is $c->spot_min_max->{low},  102, 'spot_min is 102';
    is $c->spot_min_max->{high}, 103, 'spot_max is 103';
};

subtest 'lookback expiry conditions' => sub {
    foreach my $test_case (['LBFLOATCALL', 2], ['LBFLOATPUT', 0], ['LBHIGHLOW', 2]) {
        note "testing for $test_case->[0]";
        BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;
        my $now    = Date::Utility->new;
        my $expiry = $now->plus_time_interval('1m');
        my $args   = {
            bet_type     => $test_case->[0],
            underlying   => 'R_100',
            date_start   => $now,
            date_pricing => $expiry->epoch + 1,
            date_expiry  => $expiry,
            currency     => 'USD',
            multiplier   => 1,
            amount_type  => 'multiplier',
        };
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                underlying => 'R_100',
                quote      => $_->[0],
                epoch      => $_->[1],
            }) for ([102, $now->epoch + 1], [103, $now->epoch + 2], [104, $now->epoch + 59]);
        my $c = produce_contract($args);
        ok !$c->is_atm_bet, 'non-ATM contract';
        ok $c->is_expired, 'contract is expired';
        is $c->exit_tick->quote, 104, 'exit tick is present';
        ok !$c->is_valid_exit_tick, 'not valid exit tick because we are still waiting for the next tick';
        is $c->value,     $test_case->[1], 'value is ' . $test_case->[1];
        is $c->bid_price, $test_case->[1], 'bid price ' . $test_case->[1];
        ok !$c->is_valid_to_sell, 'not valid to sell';
        is $c->primary_validation_error->message_to_client->[0],
            'Please wait for contract settlement. The final settlement price may differ from the indicative price.', 'correct error message';

        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            quote      => 105,
            epoch      => $now->epoch + 61,
        });
        $c = produce_contract($args);
        ok $c->is_expired, 'contract is expired';
        is $c->exit_tick->quote, 104, 'exit tick present';
        ok $c->is_valid_exit_tick, 'exit tick is valid';
        is $c->value,              $test_case->[1], 'value is ' . $test_case->[1];
        is $c->bid_price,          $test_case->[1], 'bid price ' . $test_case->[1];
        ok $c->is_valid_to_sell,   'valid to sell';
    }
};

done_testing();
