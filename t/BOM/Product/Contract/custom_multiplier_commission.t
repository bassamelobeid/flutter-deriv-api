#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::MockModule;

use Date::Utility;
use Math::Util::CalculatedValue::Validatable;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Config::QuantsConfig;
use BOM::Config::Chronicle;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

my $now = Date::Utility->new('2020-06-10');

my $qc = BOM::Config::QuantsConfig->new(
    chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
    chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
    recorded_date    => $now->minus_time_interval('4h'),
);

my $args = {
    bet_type     => 'multup',
    stake        => 100,
    currency     => 'USD',
    date_start   => $now,
    date_pricing => $now,
};

subtest 'multiplier commission adjustment' => sub {
    clear_config();

    my %config;
    $config{test2} = {
        staff                 => 'abc',
        name                  => 'test2',
        underlying_symbol     => ['frxUSDJPY'],
        currency_symbol       => ['USD'],
        start_time            => $now->epoch,
        end_time              => $now->plus_time_interval('1h')->epoch,
        commission_adjustment => 3.0,
        dc_commission         => 0.01,
        min_multiplier        => 50,
        max_multiplier        => 500,
    };

    $qc->save_config('custom_multiplier_commission', \%config);

    $args->{underlying} = 'frxEURUSD';
    $args->{multiplier} = '50';
    my $c = produce_contract($args);

    my $custom_commission = $c->_get_valid_custom_commission_adjustment;

    is $custom_commission->{commission_adj}, 3,    'expected commission adjustment';
    is $custom_commission->{dc_commission},  0.01, 'expected dc commission';

    $args->{underlying} = 'frxEURCAD';
    $c = produce_contract($args);

    $custom_commission = $c->_get_valid_custom_commission_adjustment;
    is $custom_commission->{commission_adj}, undef, 'expected undef commission adjustment';

    $args->{underlying}   = 'frxEURUSD';
    $args->{date_start}   = $now->plus_time_interval('2h');
    $args->{date_pricing} = $now->plus_time_interval('2h');

    $c                 = produce_contract($args);
    $custom_commission = $c->_get_valid_custom_commission_adjustment;
    is $custom_commission->{commission_adj}, undef, 'expected undef commission adjustment';
};

sub clear_config {
    $qc->chronicle_writer->set('quants_config', 'commission', {}, $now->minus_time_interval('4h'));
}

done_testing();
