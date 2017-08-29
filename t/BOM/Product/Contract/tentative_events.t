#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Product::ContractFactory qw( produce_contract );
use Test::MockModule;

my $mocked_decimate = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked_decimate->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + rand(0.1)} } (0 .. 80)];
    });

my $now             = Date::Utility->new;
my $ten_minutes_ago = $now->minus_time_interval('10m');
my $mock            = Test::MockModule->new('BOM::Product::Contract');
$mock->mock(
    '_applicable_economic_events',
    sub {
        [{
                symbol                 => 'USD',
                estimated_release_date => $now->epoch,
                event_name             => 'Construction Spending m/m',
                impact                 => 5,
                is_tentative           => 1,
                blankout               => $ten_minutes_ago->epoch,
                blankout_end           => $now->epoch,
            }];
    });

my $params = {
    bet_type     => 'CALL',
    underlying   => 'frxUSDJPY',
    current_spot => 100,
    barrier      => 100.011,
    date_start   => $ten_minutes_ago,
    date_pricing => $ten_minutes_ago,
    duration     => '1h',
    currency     => 'USD',
    payout       => 100,
};

subtest 'tentative events' => sub {
    my $c = produce_contract($params);
    ok @{$c->tentative_events}, 'apply tentative event if contract starts at the blankout period';
    $params->{date_start} = $params->{date_pricing} = $ten_minutes_ago->minus_time_interval('1m');
    $c = produce_contract($params);
    ok @{$c->tentative_events}, 'apply tentative event if contract spans the blankout period';
    $params->{date_start} = $params->{date_pricing} = $ten_minutes_ago->minus_time_interval('1h');
    $c = produce_contract($params);
    ok @{$c->tentative_events}, 'apply tentative event if contract expires at the blankout period';
    $params->{underlying} = 'frxAUDJPY';
    $c = produce_contract($params);
    ok !@{$c->tentative_events}, 'only applied to direct pairs';
    $params->{date_start} = $params->{date_pricing} = $ten_minutes_ago->minus_time_interval('1h1s');
    $c = produce_contract($params);
    ok !@{$c->tentative_events}, 'does not apply tentative event if contract starts & expires before blankout period';
    $params->{date_start} = $params->{date_pricing} = $now->plus_time_interval('1s');
    $c = produce_contract($params);
    ok !@{$c->tentative_events}, 'does not apply tentative event if contract starts & expires after blankout period';
};

done_testing();
