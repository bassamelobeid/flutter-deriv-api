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

my $args = {
    bet_type     => 'CALL',
    barrier      => 'S10P',
    date_start   => $now,
    date_pricing => $now,
    duration     => '1h',
    payout       => 10,
    currency     => 'JPY',
};

my $mock = Test::MockModule->new('BOM::Product::Pricing::Engine::Intraday::Forex');
$mock->mock(
    'intraday_vanilla_delta',
    sub {
        return Math::Util::CalculatedValue::Validatable->new(
            name        => 'intraday_vanilla_delta',
            description => 'BS pricing based on realized vols',
            set_by      => __PACKAGE__,
            base_amount => 0.1
        );
    });

subtest 'match/mismatch condition for commission adjustment' => sub {
    clear_config();
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

    $args->{underlying} = 'frxGBPJPY';
    my $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, 'zero markup if no matching config';
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

subtest 'delta range' => sub {
    clear_config();
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
    };
    foreach my $u_symbol (keys %$expected) {
        $args->{underlying} = $u_symbol;
        for my $delta (0.11, 0.23, 0.43, 0.71, 0.92) {
            $mock->mock(
                'intraday_vanilla_delta',
                sub {
                    return Math::Util::CalculatedValue::Validatable->new(
                        name        => 'intraday_vanilla_delta',
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

subtest 'bias long' => sub {
    clear_config();
    $qc->save_config(
        'commission',
        {
            name            => 'test1',
            currency_symbol => 'AUD',
            start_time      => $now->epoch,
            end_time        => $now->plus_time_interval('1h')->epoch,
            bias            => 'long',
            partitions      => [{
                    partition_range => '0-1',
                    cap_rate        => 0.5,
                    floor_rate      => 0.05,
                    centre_offset   => 0,
                    width           => 0.5,
                    flat            => 0,
                },
            ],
        });
    $args->{underlying} = 'frxAUDJPY';
    $args->{bet_type}   = 'CALLE';
    note('bias is set to long on AUD');
    my $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.5, '0.5 event markup for CALLE-frxAUDJPY';
    $args->{bet_type} = 'PUT';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, '0 event markup for PUT-frxAUDJPY';
    $args->{underlying} = 'frxEURAUD';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.5, '0.5 event markup for PUT-frxEURAUD';
    $args->{bet_type} = 'CALL';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, '0 event markup for CALL-frxEURAUD';
    $qc->save_config(
        'commission',
        {
            name            => 'test2',
            currency_symbol => 'USD',
            start_time      => $now->epoch,
            end_time        => $now->plus_time_interval('1h')->epoch,
            bias            => 'short',
            partitions      => [{
                    partition_range => '0-1',
                    cap_rate        => 0.6,
                    floor_rate      => 0.05,
                    centre_offset   => 0,
                    width           => 0.5,
                    flat            => 0,
                },
            ],
        });

    $args->{underlying} = 'frxUSDJPY';
    $args->{bet_type}   = 'CALLE';
    note('bias is set to short on USD');
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, '0 event markup for CALLE-frxUSDJPY';
    $args->{bet_type} = 'PUT';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.6, '0.6 event markup for PUT-frxUSDJPY';
    $args->{underlying} = 'frxEURUSD';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, '0 event markup for PUT-frxEURUSD';
    $args->{bet_type} = 'CALL';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.6, '0.6 event markup for CALL-frxEURUSD';

    $args->{underlying} = 'frxAUDUSD';
    $args->{bet_type}   = 'PUT';
    $c                  = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, '0 event markup for PUT-frxAUDUSD';
    $args->{bet_type} = 'CALL';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.6, '0.6 event markup for CALL-frxAUDUSD';

};

subtest 'ITM check on callput' => sub {
    clear_config();
    $mock->mock(
        'intraday_vanilla_delta',
        sub {
            return Math::Util::CalculatedValue::Validatable->new(
                name        => 'intraday_vanilla_delta',
                description => 'BS pricing based on realized vols',
                set_by      => __PACKAGE__,
                base_amount => 0.9
            );
        });
    $qc->save_config(
        'commission',
        {
            name              => 'test1',
            underlying_symbol => 'frxUSDJPY',
            start_time        => $now->epoch,
            end_time          => $now->plus_time_interval('1h')->epoch,
            bias              => 'long',
            partitions        => [{
                    partition_range => '0.5-1',
                    cap_rate        => 0.5,
                    floor_rate      => 0.05,
                    centre_offset   => 0,
                    width           => 0.5,
                    flat            => 0,
                },
            ],
        });
    $args->{date_start} = $args->{date_pricing} = $now->epoch;
    $args->{underlying} = 'frxUSDJPY';
    $args->{bet_type}   = 'CALLE';
    my $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.5, 'charged commission for ITM CALLE';
    $args->{bet_type} = 'PUT';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, 'does not charge for OTM PUT';
    $args->{bet_type} = 'CALLE';
    $args->{barrier}  = 'S0P';
    $c                = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, 'does not charge for ATM contracts';
};

sub clear_config {
    $qc->chronicle_writer->set('quants_config', 'commission', {}, $now->minus_time_interval('4h'));
}
done_testing();
