#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::NoWarnings;

use BOM::Market::Exchange;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

my $date = Date::Utility->new('2013-12-01');
note("Exchange tests for_date " . $date->date);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'holiday',
    {
        recorded_date => $date,
        calendar      => {
            "25-Dec-2013" => {
                "Christmas Day" => [qw(FOREX)],
            },
        },
    });

subtest 'weight on' => sub {
    my $chritmas = Date::Utility->new('2013-12-25');
    my $forex = BOM::Market::Exchange->new('FOREX', $date);
    ok $forex->has_holiday_on($chritmas), 'has holiday on ' . $chritmas->date;
    is $forex->weight_on($date), 0, 'weight is zero on a holiday';
    my $weekend = Date::Utility->new('2013-12-8');
    note($weekend->date . ' is a weekend');
    is $forex->weight_on($weekend), 0, 'weight is zero on weekend';
    my $pseudo_holiday_date = Date::Utility->new('2013-12-24');
    note($pseudo_holiday_date->date . ' is a pseudo holiday');
    is $forex->weight_on($pseudo_holiday_date), 0.5, 'zero for pseudo holiday';
    my $trading_date = Date::Utility->new('2013-12-2');
    is $forex->weight_on($trading_date), 1, 'weight is 1 on a trading day';
};
