#!/usr/bin/perl

use strict;
use warnings;

use Test::MockTime qw(set_absolute_time);
use Test::More;
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Market::DataDecimate;
use Date::Utility;
use Net::EmptyPort qw(empty_port);
use BOM::Feed::Distributor;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'holiday',
    {
        calendar      => {Date::Utility->new('2017-12-18')->epoch => {'test holiday' => ['FOREX']}},
        recorded_date => Date::Utility->new,
    });

subtest 'hybrid fetch on tuesday where monday is a holiday' => sub {
    my $tuesday = Date::Utility->new('2017-12-19');
    my @ticks = map { +{symbol => 'frxUSDJPY', epoch => $_, quote => 100} } ($tuesday->minus_time_interval('30m')->epoch .. $tuesday->epoch);
    fill_distributor_ticks(\@ticks);
    my @decimate_ticks = map { +{symbol => 'frxUSDJPY', epoch => $_, quote => 99} } ($tuesday->epoch .. $tuesday->plus_time_interval('30m')->epoch);
    fill_decimate_ticks(\@decimate_ticks);
    my $dc = BOM::Market::DataDecimate->new;

    foreach my $test ([
            $tuesday->minus_time_interval('20m'),
            $tuesday,
            [{
                    index => 79,
                    quote => 100,
                    epoch => 1513555185
                },
                {
                    index => 80,
                    quote => 99,
                    epoch => 1513555200
                }]
        ],
        [
            $tuesday->minus_time_interval('19m'),
            $tuesday->plus_time_interval('1m'),
            [{
                    index => 75,
                    quote => 100,
                    epoch => 1513555185
                },
                {
                    index => 76,
                    quote => 99,
                    epoch => 1513555200
                }]
        ],
        [
            $tuesday->minus_time_interval('15m'),
            $tuesday->plus_time_interval('5m'),
            [{
                    index => 59,
                    quote => 100,
                    epoch => 1513555185
                },
                {
                    index => 60,
                    quote => 99,
                    epoch => 1513555200
                }]
        ],
        [
            $tuesday->plus_time_interval('10m'),
            $tuesday->plus_time_interval('30m'),
            [{
                    index => 0,
                    quote => 99,
                    epoch => 1513555800
                },
                {
                    index => 80,
                    quote => 99,
                    epoch => 1513557000
                }]])
    {
        my $t = $dc->_get_decimate_from_cache({
            symbol      => 'frxUSDJPY',
            start_epoch => $test->[0]->epoch,
            end_epoch   => $test->[1]->epoch,
        });
        note('checking for ' . $test->[0]->datetime . ' to ' . $test->[1]->datetime);
        foreach my $switch (@{$test->[2]}) {
            is $t->[$switch->{index}]->{epoch}, $switch->{epoch} + 86400, 'correct epoch';
            is $t->[$switch->{index}]->{quote}, $switch->{quote}, 'correct quote';
        }
    }
};

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'holiday',
    {
        calendar      => {},
        recorded_date => Date::Utility->new,
    });
note('holiday on monday is removed');

subtest 'hybrid fetch on tuesday where monday is a trading day' => sub {
    my $tuesday = Date::Utility->new('2017-12-19');
    my @decimate_ticks = map { +{symbol => 'frxUSDJPY', epoch => $_, quote => 99} }
        ($tuesday->minus_time_interval('30m')->epoch .. $tuesday->plus_time_interval('30m')->epoch);
    fill_decimate_ticks(\@decimate_ticks);
    my $dc = BOM::Market::DataDecimate->new;
    foreach my $test (
        [$tuesday->minus_time_interval('20m'), $tuesday,],
        [$tuesday->minus_time_interval('19m'), $tuesday->plus_time_interval('1m'),],
        [$tuesday->minus_time_interval('15m'), $tuesday->plus_time_interval('5m'),],
        [$tuesday->plus_time_interval('10m'),  $tuesday->plus_time_interval('30m'),])
    {
        my $t = $dc->_get_decimate_from_cache({
            symbol      => 'frxUSDJPY',
            start_epoch => $test->[0]->epoch,
            end_epoch   => $test->[1]->epoch,
        });
        ok $_->{quote} == 99, 'all ticks retrieve from original source' for @$t;
    }
};

done_testing();

sub fill_decimate_ticks {
    my $ticks = shift;

    my $decimate_cache = BOM::Market::DataDecimate->new;
    my $decimate_data  = Data::Decimate::decimate($decimate_cache->sampling_frequency->seconds, $ticks);
    my $decimate_key   = $decimate_cache->_make_key($ticks->[0]->{symbol}, 1);

    foreach my $single_data (@$decimate_data) {
        $decimate_cache->_update(
            $decimate_cache->redis_write,
            $decimate_key,
            $single_data->{decimate_epoch},
            $decimate_cache->encoder->encode($single_data));
    }
}

sub fill_distributor_ticks {
    my $ticks = shift;
    my $dist;

    for (@$ticks) {
        set_absolute_time($_->{epoch});
        $dist //= BOM::Feed::Distributor->new(
            no_bad_ticks_log => 1,
            port             => empty_port(),
        );
        $dist->_save_tick_to_redis($_);
    }
}
