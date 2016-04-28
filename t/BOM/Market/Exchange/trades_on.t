#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::NoWarnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Market::Exchange;
use Test::MockModule;
use YAML::XS qw(LoadFile);

my $date = Date::Utility->new('2013-12-08');
note("Exchange tests for_date " . $date->date);

subtest 'trading days' => sub {
    my $exp       = LoadFile('/home/git/regentmarkets/bom-market/t/BOM/Market/Exchange/expected_trading_days.yml');
    my @exchanges = qw(JSC SES NYSE_SPC ASX ODLS ISE BSE FOREX JSE SWX FSE DFM EURONEXT HKSE NYSE RANDOM RANDOM_NOCTURNE TSE OSLO);

    foreach my $exchange_symbol (@exchanges) {
        my $e = BOM::Market::Exchange->new($exchange_symbol);
        for (0 .. 6) {
            is $e->trades_on($date->plus_time_interval($_ . 'd')), $exp->{$exchange_symbol}->[$_],
                'correct trading days list for ' . $exchange_symbol;
        }
    }
};

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'holiday',
    {
        recorded_date => $date,
        calendar      => {
            "25-Dec-2013" => {
                "Christmas Day" => [qw(FOREX)],
            },
            "1-Jan-2014" => {
                "New Year's Day" => [qw(FOREX)],
            },
        },
    });

subtest 'trades on holidays/pseudo-holidays' => sub {
    my @expected = qw(1 1 1 0 0 1 1 0 1 1 0 0 1 1 0);
    my $mocked   = Test::MockModule->new('BOM::Market::Exchange');
    $mocked->mock('_object_expired', sub { 1 });
    my $forex = BOM::Market::Exchange->new('FOREX', $date);
    my $counter = 0;
    foreach my $days (sort { $a <=> $b } keys %{$forex->pseudo_holidays}) {
        my $date = Date::Utility->new(0)->plus_time_interval($days . 'd');
        is $forex->trades_on($date), $expected[$counter];
        $counter++;
    }
};
