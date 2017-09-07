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

my $qc = BOM::Platform::QuantsConfig->new(
    chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
    chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
);

$qc->save_config(
    'commission',
    {
        name            => 'test1',
        cap_rate        => 0.45,
        floor_rate      => 0.05,
        center_offset   => 0,
        width           => 0.5,
        currency_symbol => 'EUR',
    });
$qc->save_config(
    'commission',
    {
        name              => 'test2',
        cap_rate          => 0.25,
        floor_rate        => 0.05,
        center_offset     => 0,
        width             => 0.5,
        underlying_symbol => 'frxUSDJPY',
        currency_symbol   => 'AUD'
    });

$qc->save_config(
    'commission',
    {
        name          => 'test3',
        cap_rate      => 0.15,
        floor_rate    => 0.05,
        center_offset => 0,
        width         => 0.5,
        contract_type => 'CALLE,ONETOUCH'
    });

my $now  = Date::Utility->new('2017-09-07');
my $args = {
    bet_type     => 'CALL',
    barrier      => 'S0P',
    date_start   => $now,
    date_pricing => $now,
    duration     => '1h',
    payout       => 10,
    currency     => 'JPY',
};

subtest 'match/mismatch condition for commission adjustment' => sub {
    $args->{underlying} = 'frxGBPJPY';
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
    my $c = produce_contract($args);
    is $c->pricing_engine->economic_events_volatility_risk_markup->amount, 0, 'zero markup if no matching config';
    $args->{bet_type} = 'CALLE';
    $c = produce_contract($args);
    is $c->pricing_engine->economic_events_volatility_risk_markup->amount, 0.15, '0.15 markup for matching contract type config';
    $args->{underlying} = 'frxUSDJPY';
    $c = produce_contract($args);
    is $c->pricing_engine->economic_events_volatility_risk_markup->amount, 0.25, '0.25 markup for matching both underlying & contract type config';
    $args->{underlying} = 'frxEURJPY';
    $c = produce_contract($args);
    is $c->pricing_engine->economic_events_volatility_risk_markup->amount, 0.45, '0.45 markup for matching both underlying & contract type config';
};

done_testing();
