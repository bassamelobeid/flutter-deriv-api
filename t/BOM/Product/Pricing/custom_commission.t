#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::MockModule;

use Date::Utility;
use Math::Util::CalculatedValue::Validatable;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Platform::QuantsConfig;
use BOM::Platform::Chronicle;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

my $now = Date::Utility->new('2017-09-07');
my $qc  = BOM::Platform::QuantsConfig->new(
    chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
    chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
    recorded_date    => $now->minus_time_interval('4h'),
);

$qc->save_config(
    'commission',
    {
        name            => 'test1',
        currency_symbol => 'EUR',
        start_time      => $now->epoch,
        end_time        => $now->plus_time_interval('1h')->epoch,
        partitions      => [{
                partition_range => '0-1',
                cap_rate        => 0.45,
                floor_rate      => 0.05,
                centre_offset   => 0,
                width           => 0.5,
                flat            => 0,
            }
        ],
    });
$qc->save_config(
    'commission',
    {
        name              => 'test2',
        underlying_symbol => 'frxUSDJPY',
        currency_symbol   => 'AUD',
        start_time        => $now->epoch,
        end_time          => $now->plus_time_interval('1h')->epoch,
        partitions        => [{
                partition_range => '0-1',
                cap_rate        => 0.25,
                floor_rate      => 0.05,
                centre_offset   => 0,
                width           => 0.5,
                flat            => 0
            }
        ],
    });

$qc->save_config(
    'commission',
    {
        name          => 'test3',
        contract_type => 'CALLE,ONETOUCH',
        start_time    => $now->epoch,
        end_time      => $now->plus_time_interval('1h')->epoch,
        partitions    => [{
                partition_range => '0-1',
                cap_rate        => 0.15,
                floor_rate      => 0.05,
                centre_offset   => 0,
                width           => 0.5,
                flat            => 0
            }]});

my $args = {
    bet_type     => 'CALL',
    barrier      => 'S0P',
    date_start   => $now,
    date_pricing => $now,
    duration     => '1h',
    payout       => 10,
    currency     => 'JPY',
};

my $mock = Test::MockModule->new('BOM::Product::Pricing::Engine::Intraday::Forex');
$mock->mock(
    'base_probability',
    sub {
        return Math::Util::CalculatedValue::Validatable->new(
            name        => 'intraday_delta',
            description => 'BS pricing based on realized vols',
            set_by      => __PACKAGE__,
            base_amount => 0.1
        );
    });

subtest 'match/mismatch condition for commission adjustment' => sub {
    $args->{underlying} = 'frxGBPJPY';
    my $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, 'zero markup if no matching config';
    $args->{bet_type} = 'CALLE';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.15, '0.15 markup for matching contract type config';
    $args->{underlying} = 'frxUSDJPY';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.25, '0.25 markup for matching both underlying & contract type config';
    $args->{underlying} = 'frxEURJPY';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.45, '0.45 markup for matching both underlying & contract type config';
};

subtest 'timeframe' => sub {
    $args->{date_start} = $args->{date_pricing} = $now->plus_time_interval('1h1s');
    my $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, 'zero markup if contract start or expiry is not in timeframe';
    $args->{date_start} = $args->{date_pricing} = $now->minus_time_interval('1h1s');
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, 'zero markup if contract start or expiry is not in timeframe';
    $args->{date_start} = $args->{date_pricing} = $now->minus_time_interval('2h1s');
    $args->{duration}   = '3h1s';
    $c                  = produce_contract($args);
    ok $c->pricing_engine->event_markup->amount > 0, 'has markup if contract spans the timeframe';
};

subtest 'delta range & reverse delta' => sub {
    $qc->chronicle_writer->set('quants_config', 'commission', {}, $now->minus_time_interval('4h'));
    $qc->save_config(
        'commission',
        {
            name            => 'test1',
            currency_symbol => 'AUD',
            start_time      => $now->epoch,
            end_time        => $now->plus_time_interval('1h')->epoch,
            partitions      => [{
                    partition_range => '0-0.5',
                    cap_rate        => 0.5,
                    floor_rate      => 0.05,
                    centre_offset   => 0,
                    width           => 0.5,
                    flat            => 0,
                },
                {
                    partition_range => '0.5-1',
                    cap_rate        => 0.15,
                    floor_rate      => 0.01,
                    centre_offset   => 0,
                    width           => 0.3,
                    flat            => 0,
                }
            ],
        });
    $args->{date_start} = $args->{date_pricing} = $now;
    my $expected = {
        frxAUDJPY => {
            0.11 => 0.5,
            0.23 => 0.5,
            0.43 => 0.078989408394779,
            0.71 => 0.15,
            0.92 => 0.15
        },
        frxEURAUD => {
            0.11 => 0.15,
            0.23 => 0.15,
            0.43 => 0.0484933967540396,
            0.71 => 0.469595144157318,
            0.92 => 0.5
        },
    };
    foreach my $u_symbol (keys %$expected) {
        $args->{underlying} = $u_symbol;
        for my $delta (0.11, 0.23, 0.43, 0.71, 0.92) {
            $mock->mock(
                'base_probability',
                sub {
                    return Math::Util::CalculatedValue::Validatable->new(
                        name        => 'intraday_delta',
                        description => 'BS pricing based on realized vols',
                        set_by      => __PACKAGE__,
                        base_amount => $delta,
                    );
                });
            my $c = produce_contract($args);
            is $c->pricing_engine->event_markup->amount, $expected->{$u_symbol}{$delta}, "event markup for $u_symbol at delta[$delta]";
        }
    }
};

done_testing();
