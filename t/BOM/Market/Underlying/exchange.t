use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::Warnings;
use Data::Chronicle::Mock;

use BOM::Config::Chronicle;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::Test::Data::Utility::UnitTestMarketData;

#tests related to underlying-exchange are moved here because exchange is moved to Q::F
my $date                 = Date::Utility->new('2013-12-01');    # first of December 2014
my $trade_start          = Date::Utility->new('30-Mar-13');
my $sunday               = Date::Utility->new('7-Apr-13');
my $trade_end            = Date::Utility->new('8-Apr-13');
my $trade_end2           = Date::Utility->new('9-Apr-13');      # Just to avoid memoization on weighted_days_in_period
my $friday               = Date::Utility->new('2016-03-25');
my $normal_thursday      = Date::Utility->new('2016-03-24');
my $early_close_thursday = Date::Utility->new('2016-12-24');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'holiday',
    {
        recorded_date => $date,
        calendar      => {
            "6-May-2013" => {
                "Early May Bank Holiday" => [qw(LSE)],
            },
            "25-Dec-2013" => {
                "Christmas Day" => [qw(LSE FOREX METAL)],
            },
            "1-Jan-2014" => {
                "New Year's Day" => [qw(LSE FOREX METAL)],
            },
            "1-Apr-2013" => {
                "Easter Monday" => [qw(LSE)],
            },
        },
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'partial_trading',
    {
        recorded_date => $date,
        type          => 'early_closes',
        calendar      => {
            '24-Dec-2009' => {
                '4h30m' => ['HKSE'],
            },
            '24-Dec-2010' => {'12h30m' => ['LSE']},
            '24-Dec-2013' => {
                '12h30m' => ['LSE'],
            },
            '22-Dec-2016' => {
                '18h' => ['FOREX METAL'],
            },
        },
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'partial_trading',
    {
        recorded_date => $date,
        type          => 'late_opens',
        calendar      => {
            '24-Dec-2010' => {
                '2h30m' => ['HKSE'],
            },
        },
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(AUD GBP EUR USD HKD);

done_testing;
1;
