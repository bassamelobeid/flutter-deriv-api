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
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use Test::MockModule;

my $mock = Test::MockModule->new('BOM::Config::QuantsConfig');
$mock->mock(
    'save_config',
    sub {
        my ($self, $config_type, $args) = @_;

        my $method = '_' . $config_type;
        my $config = $self->can($method) ? $self->$method($args) : $args;

        $self->chronicle_writer->set('quants_config', $config_type, $config, $self->recorded_date);

        return $config->{$args->{name}} if $args->{name};
        return $config;
    });

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

subtest 'custom commission adjustment' => sub {
    clear_config();
    subtest 'set commission_adjustment=3 & dc_commission=0.01 for currency_symbol=USD from '
        . $now->datetime . ' to '
        . $now->plus_time_interval('1h')->datetime => sub {
        my %config = (
            test2 => {
                staff                 => 'abc',
                name                  => 'test2',
                currency_symbol       => ['USD'],
                start_time            => $now->epoch,
                end_time              => $now->plus_time_interval('1h')->epoch,
                commission_adjustment => 3.0,
                dc_commission         => 0.5,
                min_multiplier        => 50,
                max_multiplier        => 500,
            });
        $qc->save_config('custom_multiplier_commission', \%config);
        $args->{underlying} = 'frxEURUSD';
        $args->{multiplier} = '50';
        my $c = produce_contract($args);

        my $custom_commission = $c->_get_valid_custom_commission_adjustment;

        is $custom_commission->{commission_adj}, 3,    'expected commission adjustment';
        is $custom_commission->{dc_commission},  0.5,  'expected dc commission';
        is $c->dc_commission_multiplier,         0.75, 'floored at 0.75';

        $args->{underlying} = 'frxEURCAD';
        $c = produce_contract($args);

        $custom_commission = $c->_get_valid_custom_commission_adjustment;
        is $custom_commission->{commission_adj}, undef, 'expected undef commission adjustment';

        $args->{underlying}   = 'frxEURUSD';
        $args->{date_start}   = $now->plus_time_interval('2h');
        $args->{date_pricing} = $now->plus_time_interval('2h');

        $c                 = produce_contract($args);
        $custom_commission = $c->_get_valid_custom_commission_adjustment;
        is $custom_commission->{commission_adj}, undef, 'expected undef commission adjustment if contract date start is after the start & end time';

        $args->{date_start}   = $now->minus_time_interval(1);
        $args->{date_pricing} = $now->minus_time_interval(1);
        $c                    = produce_contract($args);
        $custom_commission    = $c->_get_valid_custom_commission_adjustment;
        is $custom_commission->{commission_adj}, undef, 'expected undef commission adjustment if contract date start is before the start & end time';
        };

    subtest 'set commission_adjustment=5 & dc_commission=5 for underlying_symbol=frxUSDJPY from '
        . $now->datetime . ' to '
        . $now->plus_time_interval('1h')->datetime => sub {
        my %config = (
            test3 => {
                staff                 => 'abc',
                name                  => 'test3',
                underlying_symbol     => ['frxUSDJPY'],
                start_time            => $now->epoch,
                end_time              => $now->plus_time_interval('1h')->epoch,
                commission_adjustment => 4.0,
                dc_commission         => 5,
                min_multiplier        => 50,
                max_multiplier        => 500,
            });
        $qc->save_config('custom_multiplier_commission', \%config);
        $args->{underlying}   = 'frxUSDJPY';
        $args->{multiplier}   = 50;
        $args->{date_pricing} = $args->{date_start} = $now;
        my $c                 = produce_contract($args);
        my $custom_commission = $c->_get_valid_custom_commission_adjustment;
        is $custom_commission->{commission_adj}, 4, 'max commission adjustment is taken if there\'s an overlap.';
        is $custom_commission->{dc_commission},  5, 'DC commission set to 5.';
        is $c->dc_commission_multiplier,         4, 'DC commission multiplier capped at 4.';

        # set custom commission multiplier to 5
        $config{test3}{commission_adjustment} = 5;
        $qc->save_config('custom_multiplier_commission', \%config);
        $c                 = produce_contract($args);
        $custom_commission = $c->_get_valid_custom_commission_adjustment;
        is $custom_commission->{commission_adj}, 5, 'custom commission multiplier set to 5.';
        is $c->commission_multiplier,            4, 'commission multiplier is capped at 4.';
        };

    subtest 'test commission scaling factor with different either min or max range or none' => sub {
        clear_config();
        my %config = (
            test3 => {
                staff                 => 'abc',
                name                  => 'test3',
                underlying_symbol     => ['frxUSDJPY'],
                start_time            => $now->epoch,
                end_time              => $now->plus_time_interval('1h')->epoch,
                commission_adjustment => 4.0,
                dc_commission         => 3,
                min_multiplier        => 200,
            });
        $qc->save_config('custom_multiplier_commission', \%config);
        $args->{underlying} = 'frxUSDJPY';
        $args->{multiplier} = 300;
        $args->{date_start} = $args->{date_pricing} = $now;
        my $c = produce_contract($args);
        is $c->commission_multiplier,    1.047, 'commission multiplier is 1 if only min_multiplier is specified';
        is $c->dc_commission_multiplier, 1,     'dc commission multiplier is 1 if only min_multiplier is specified';

        delete $config{test3}{min_multiplier};
        $qc->save_config('custom_multiplier_commission', \%config);
        $c = produce_contract($args);
        is $c->commission_multiplier,    4, 'commission multiplier is 4 if commission is specified without min & max range';
        is $c->dc_commission_multiplier, 3, 'dc commission multiplier is 3 if commission is specified without min & max range';
    };
};

sub clear_config {
    $qc->chronicle_writer->set('quants_config', 'commission', {}, $now->minus_time_interval('4h'));
}

done_testing();
