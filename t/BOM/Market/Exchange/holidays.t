#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Exception;
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
            "6-May-2013" => {
                "Early May Bank Holiday" => [qw(LSE)],
            },
            "25-Dec-2013" => {
                "Christmas Day" => [qw(LSE FOREX)],
            },
            "1-Jan-2014" => {
                "New Year's Day" => [qw(LSE FOREX)],
            },
            "1-Apr-2013" => {
                "Easter Monday" => [qw(LSE)],
            },
        },
    });

subtest 'holidays' => sub {
    my ($LSE, $FOREX, $RANDOM) = map { BOM::Market::Exchange->new($_, $date) } qw(LSE FOREX RANDOM);
    is $LSE->for_date->epoch, $date->epoch, 'for_date properly set in Exchange';
    my %expected_holidays = (
        15831 => 'Early May Bank Holiday',
        16064 => 'Christmas Day',
        16071 => 'New Year\'s Day',
        15796 => 'Easter Monday',
    );
    lives_ok {
        my $holidays = $LSE->holidays;
        is scalar(keys %$holidays), scalar(keys %expected_holidays), 'holidays retrieved is as expected';
        for (keys %expected_holidays) {
            is $holidays->{Date::Utility->new($_)->epoch}, $expected_holidays{$_}, 'matches holiday';
        }
    }
    'check holiday accuracy';

    ok($LSE->has_holiday_on(Date::Utility->new('6-May-13')),    'LSE has holiday on 6-May-13.');
    ok(!$FOREX->has_holiday_on(Date::Utility->new('6-May-13')), 'FOREX is open on LSE holiday 6-May-13.');
    ok($FOREX->has_holiday_on(Date::Utility->new('25-Dec-13')), 'FOREX has holiday on 25-Dec-13.');
    ok(!$LSE->has_holiday_on(Date::Utility->new('7-May-13')),   'LSE is open on 7-May-13.');
    ok(!$LSE->has_holiday_on(Date::Utility->new('26-Dec-13')), '26-Dec-13 is not a real holiday');
};

subtest 'pseudo holidays' => sub {
    my $FOREX = BOM::Market::Exchange->new('FOREX', $date);
    my $start = Date::Utility->new('25-Dec-13')->minus_time_interval('7d');
    note("seven days before and after Chritmas is pseudo-holiday period");
    for (map {$start->plus_time_interval($_ .'d')} (0 .. 14)) {
        ok $FOREX->pseudo_holidays->{$_->days_since_epoch}, 'pseudo holiday on ' . $_->date;
    }

    my $one_day_before_start = $start->minus_time_interval('1d');
    ok !$FOREX->pseudo_holidays->{$one_day_before_start->days_since_epoch}, 'not a pseudo holiday on ' . $one_day_before_start->date;
};

