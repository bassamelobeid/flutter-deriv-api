use Test::Most;
use Test::MockModule;
use File::Spec;
use Test::FailWarnings;
use Test::MockTime qw( :all );
use Test::MockObject::Extends;
use Test::MockModule;
use JSON qw(decode_json);
use Time::Local ();

use Readonly;
Readonly::Scalar my $HKSE_TRADE_DURATION_DAY => ((2 * 3600 + 29 * 60) + (2 * 3600 + 40 * 60));
Readonly::Scalar my $HKSE_TRADE_DURATION_MORNING => 2 * 3600 + 29 * 60;
Readonly::Scalar my $HKSE_TRADE_DURATION_EVENING => 2 * 3600 + 40 * 60;

use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange');

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'LSE',
        currency         => 'GBP',
        delay_amount     => 15,
        trading_timezone => 'Europe/London',
        holidays         => {
            "1-Jan-2013"  => "New Year's Day",
            "29-Mar-2013" => "Good Friday",
            "1-Apr-2013"  => "Easter Monday",
            "6-May-2013"  => "Early May Bank Holiday",
            "27-May-2013" => "Late May Bank Holiday",
            "26-Aug-2013" => "Summer Bank Holiday",
            "25-Dec-2013" => "Christmas Day",
            "26-Dec-2013" => "Boxing Day",
            "2013-12-20"  => "pseudo-holiday",
            "2013-12-23"  => "pseudo-holiday",
            "2013-12-24"  => "pseudo-holiday",
            "2013-12-27"  => "pseudo-holiday",
            "2013-12-30"  => "pseudo-holiday",
            "2013-12-31"  => "pseudo-holiday",
            "1-Jan-2014"  => "New Year's Day",
            "18-Apr-2014" => "Good Friday",
            "21-Apr-2014" => "Easter Monday",
            "5-May-2014"  => "Early May Bank Holiday",
            "26-May-2014" => "Late May Bank Holiday",
            "25-Aug-2014" => "Summer Bank Holiday",
            "25-Dec-2014" => "Christmas Day",
            "26-Dec-2014" => "Boxing Day",
            "2014-01-02"  => "pseudo-holiday",
            "2014-01-03"  => "pseudo-holiday",
        },
        market_times => {
            dst => {
                daily_close      => '15h30m',
                daily_open       => '7h',
                daily_settlement => '18h30m',
            },
            standard => {
                daily_close      => '16h30m',
                daily_open       => '8h',
                daily_settlement => '19h30m'
            },
            partial_trading => {
                dst_open       => '7h',
                dst_close      => '11h30m',
                standard_open  => '8h',
                standard_close => '12h30m',
            },
            early_closes => {
                '24-Dec-2010' => '12h30m',
                '24-Dec-2013' => '12h30m',
            },
        },
    },
);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'RANDOM',
        open_on_weekends => 1,
        holidays         => {},
        market_times     => {
            early_closes => {},
            standard     => {
                daily_close      => '23h59m59s',
                daily_open       => '0s',
                daily_settlement => '23h59m59s',
            },
            partial_trading => {},
        },
    },
);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'RANDOM_NOCTURNE',
        open_on_weekends => 1,
        holidays         => {},
        market_times     => {
            early_closes => {},
            standard     => {
                daily_close      => '11h59m59s',
                daily_open       => '-12h',
                daily_settlement => '11h59m59s',
            },
            partial_trading => {},
        },
    },
);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol       => 'FSE',
        currency     => 'EUR',
        delay_amount => 15,
        market_times => {
            early_closes => {},
            standard     => {
                daily_close      => '16h30m',
                daily_open       => '8h',
                daily_settlement => '19h30m',
            },
            dst => {
                daily_close      => '15h30m',
                daily_open       => '7h',
                daily_settlement => '18h30m',
            },
        }
    },
);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'ASX',
        currency         => 'AUD',
        trading_timezone => 'Australia/Sydney',
        market_times     => {
            dst => {
                daily_close      => '5h',
                daily_open       => '-1h',
                daily_settlement => '8h',
            },
            standard => {
                daily_close      => '6h',
                daily_open       => '0s',
                daily_settlement => '9h',
            },
        },
    },
);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'ISE',
        currency         => 'EUR',
        trading_timezone => 'Europe/Dublin',
        market_times     => {
            dst => {
                daily_close      => '15h30m',
                daily_open       => '7h',
                daily_settlement => '21h30m',
            },
            standard => {
                daily_close      => '16h30m',
                daily_open       => '8h',
                daily_settlement => '22h30m'
            },
        },
    },
);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'NYSE',
        currency         => 'USD',
        trading_timezone => 'America/New_York',
        market_times     => {
            dst => {
                daily_close      => '20h',
                daily_open       => '13h30m',
                daily_settlement => '22h59m59s',
            },
            standard => {
                daily_close      => '21h',
                daily_open       => '14h30m',
                daily_settlement => '23h59m59s',
            },
        },
    },
);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'HKSE',
        currency         => 'HKD',
        delay_amount     => 60,
        trading_timezone => 'Asia/Hong_Kong',
        holidays         => {
            "1-Jan-2013"  => "The first day of January",
            "11-Feb-2013" => "The second day of Lunar New Year",
            "12-Feb-2013" => "The third day of Lunar New Year",
            "13-Feb-2013" => "The fourth day of Lunar New Year",
            "29-Mar-2013" => "Good Friday",
            "1-Apr-2013"  => "Easter Monday",
            "1-May-2013"  => "Labour Day",
            "17-May-2013" => "The Birthday of the Buddha",
            "12-Jun-2013" => "Tuen Ng Festival",
            "1-Jul-2013"  => "Hong Kong Special Administrative Region Establishment Day",
            "20-Sep-2013" => "The day following the Chinese Mid-Autumn Festival",
            "1-Oct-2013"  => "National Day",
            "14-Oct-2013" => "The day following Chung Yeung Festival",
            "25-Dec-2013" => "Christmas Day",
            "26-Dec-2013" => "The first weekday after Christmas Day",
            "2013-12-20"  => "pseudo-holiday",
            "2013-12-23"  => "pseudo-holiday",
            "2013-12-24"  => "pseudo-holiday",
            "2013-12-24"  => "pseudo-holiday",
            "2013-12-27"  => "pseudo-holiday",
            "2013-12-30"  => "pseudo-holiday",
            "2013-12-31"  => "pseudo-holiday",
            "1-Jan-2014"  => "New Year's Day",
            "31-Jan-2014" => "The first day of Lunar New Year",
            "3-Feb-2014"  => "The fourth day of Lunar New Year",
            "18-Apr-2014" => "Good Friday",
            "21-Apr-2014" => "Easter Monday",
            "1-May-2014"  => "Labour Day",
            "6-May-2014"  => "Buddha's Birthday",
            "2-Jun-2014"  => "Tuen Ng Festival",
            "1-Jul-2014"  => "Sar Establishment Day",
            "9-Sep-2014"  => "Day after Mid-autumn Festival",
            "1-Oct-2014"  => "National Day",
            "2-Oct-2014"  => "Chung Yeung Festival",
            "25-Dec-2014" => "Christmas Day",
            "26-Dec-2014" => "Christmas Holiday",
            "2014-01-03"  => "pseudo-holiday",
        },
        market_times => {
            late_opens => {
                '24-Dec-2010' => '2h30m',
            },
            early_closes => {
                '24-Dec-2009' => '4h30m',
            },
            standard => {
                daily_close      => '7h40m',
                daily_open       => '1h30m',
                daily_settlement => '10h40m',
                trading_breaks   => [['3h59m', '5h00m']],
            },
            partial_trading => {
                standard_open  => '1h30m',
                standard_close => '3h59m',
            },
        },
    },
);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency',        {symbol => $_}) for qw(AUD GBP EUR USD HKD);
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency_config', {symbol => $_}) for qw(GBP EUR);

use BOM::Market::Exchange;
use BOM::Market::Underlying;

my $LSE             = BOM::Market::Exchange->new('LSE');
my $FSE             = BOM::Market::Exchange->new('FSE');               # think GDAXI
my $FOREX           = BOM::Market::Exchange->new('FOREX');
my $RANDOM          = BOM::Market::Exchange->new('RANDOM');
my $RANDOM_NOCTURNE = BOM::Market::Exchange->new('RANDOM_NOCTURNE');
my $ASX             = BOM::Market::Exchange->new('ASX');
my $NYSE            = BOM::Market::Exchange->new('NYSE');
my $HKSE            = BOM::Market::Exchange->new('HKSE');
my $ISE             = BOM::Market::Exchange->new('ISE');
subtest 'Basics.' => sub {
    plan tests => 18;

    is($LSE->currency->symbol, 'GBP', 'LSE trades in GBP');
    is($FSE->currency->symbol, 'EUR', 'FSE trades in EUR');
    ok(!defined $FOREX->currency,  'FOREX has no single currency');
    ok(!defined $RANDOM->currency, 'RANDOM has no single currency');

    is($LSE->holiday_days_between(Date::Utility->new('24-Dec-13'), Date::Utility->new('3-Jan-14')), 3, "Three holidays over the year end on LSE.");

    ok($LSE->has_holiday_on(Date::Utility->new('6-May-13')),    'LSE has holiday on 6-May-13.');
    ok(!$FOREX->has_holiday_on(Date::Utility->new('6-May-13')), 'FOREX is open on LSE holiday 6-May-13.');
    ok(!$LSE->has_holiday_on(Date::Utility->new('7-May-13')),   'LSE is open on 7-May-13.');

    ok(!$LSE->trades_on(Date::Utility->new('1-Jan-14')),   'LSE doesn\'t trade on 1-Jan-14 because it is on holiday.');
    ok(!$LSE->trades_on(Date::Utility->new('12-May-13')),  'LSE doesn\'t trade on weekend (12-May-13).');
    ok($LSE->trades_on(Date::Utility->new('3-May-13')),    'LSE trades on normal day 4-May-13.');
    ok($FOREX->trades_on(Date::Utility->new('3-May-13')),  'FOREX trades on normal day 4-May-13.');
    ok(!$LSE->trades_on(Date::Utility->new('5-May-13')),   'LSE doesn\'t trade on 5-May-13 as it is a weekend day.');
    ok(!$FOREX->trades_on(Date::Utility->new('5-May-13')), 'FOREX doesn\'t trade on 5-May-13 as it is a weekend day.');
    ok($RANDOM->trades_on(Date::Utility->new('5-May-13')), 'RANDOM trades on 5-May-13 as it is open on weekends.');

    is(scalar(keys %{$FOREX->holidays}), 13, '13 FOREX holidays');
    my @real_holidays = grep { $FOREX->has_holiday_on(Date::Utility->new($_ * 86400)) } keys(%{$FOREX->holidays});
    is(scalar @real_holidays, 4, '4 real FOREX holidays');
    ok(!$FOREX->has_holiday_on(Date::Utility->new('26-Dec-13')), '26-Dec-13 is not a real holiday');
};

subtest "Holiday on weekends" => sub {
    my $trade_start = Date::Utility->new('30-Mar-13');
    my $sunday      = Date::Utility->new('7-Apr-13');
    my $trade_end   = Date::Utility->new('8-Apr-13');
    my $trade_end2  = Date::Utility->new('9-Apr-13');    # Just to avoid memoization on weighted_days_in_period
    ok $sunday->is_a_weekend, "This is a weekend";
    ok(!$LSE->has_holiday_on($sunday), 'No holiday on that sunday.');
    my $ul_LSE = BOM::Market::Underlying->new('FTSE');
    is $ul_LSE->exchange->symbol, $LSE->symbol, "This underlying's exchange is what we expect";
    is $ul_LSE->closed_weight, 0.55, 'Sanity check so that our weighted math matches :-)';
    is $ul_LSE->weighted_days_in_period($trade_start, $trade_end), 7.2,
        'Weighted period calculated correctly: 5 trading days, plus 4 weekends/holidays';

    # mock
    Test::MockObject::Extends->new($LSE);
    my $orig_holidays = $LSE->holidays;
    $LSE->mock(
        'holidays',
        sub {
            return {%$orig_holidays, 14703 => 'Test Sunday Holiday!'};
        });
    # test
    is($LSE->weight_on($sunday), 0.0, "holiday on sunday.");
    is $ul_LSE->weighted_days_in_period($trade_start, $trade_end2), 8.2,
        'Weighted period calculated correctly: 6 trading days, plus 4 weekends/holidays';

    # unmock
    $LSE->unmock('holidays');
    ok(!$LSE->has_holiday_on($sunday), 'Unmocked');
};

subtest 'Whole bunch of stuff.' => sub {
    plan tests => 116;

    is($LSE->weight_on(Date::Utility->new('2-Apr-13')), 1.0, 'open weight');
    is($LSE->weight_on(Date::Utility->new('1-Apr-13')), 0.0, 'holiday weight');
    is($LSE->weight_on(Date::Utility->new('1-Apr-13')), 0.0, 'weekend weight');

    ok(!$LSE->open_on_weekends,   'LSE not open on weekends.');
    ok(!$FOREX->open_on_weekends, 'FOREX not open on weekends.');
    ok($RANDOM->open_on_weekends, 'RANDOM is open on weekends.');

    is($FOREX->trade_date_after(Date::Utility->new('20-Dec-13'))->date, '2013-12-23', '23-Dec-13 is next trading day on FOREX after 20-Dec-13');

    is($FOREX->calendar_days_to_trade_date_after(Date::Utility->new('20-Dec-13')),
        3, '3 calendar days until next trading day on FOREX after 20-Dec-13');
    is($FOREX->calendar_days_to_trade_date_after(Date::Utility->new('27-Dec-13')),
        3, '3 calendar days until next trading day on FOREX after 27-Dec-13');
    is($FOREX->calendar_days_to_trade_date_after(Date::Utility->new('7-Mar-13')), 1, '1 calendar day until next trading day on FOREX after 7-Mar-13');
    is($FOREX->calendar_days_to_trade_date_after(Date::Utility->new('8-Mar-13')), 3,
        '3 calendar days until next trading day on FOREX after 8-Mar-13');
    is($FOREX->calendar_days_to_trade_date_after(Date::Utility->new('9-Mar-13')), 2,
        '2 calendar days until next trading day on FOREX after 9-Mar-13');
    is($FOREX->calendar_days_to_trade_date_after(Date::Utility->new('10-Mar-13')),
        1, '1 calendar day until next trading day on FOREX after 10-Mar-13');
    is($FSE->calendar_days_to_trade_date_after(Date::Utility->new('20-Dec-13')), 3, '3 calendar days until next trading day on FSE after 20-Dec-13');
    is($FSE->calendar_days_to_trade_date_after(Date::Utility->new('27-Dec-13')), 3, '3 calendar days until next trading day on FSE after 27-Dec-13');

    # testing the "use current time" methods for one date/time only.
    # Rest of tests will use the "_at" methods ("current time" ones
    # use them anyway).
    Test::MockTime::set_fixed_time('2013-05-03T09:00:00Z');
    is($LSE->is_open,   1,     'LSE is open at 9am on a trading day');
    is($LSE->will_open, undef, 'LSE will not open "later" (is it already open)');
    Test::MockTime::restore_time();

    # before opening time on an LSE trading day:
    my $six_am       = Date::Utility->new('3-May-13 06:00:00');
    my $six_am_epoch = $six_am->epoch;
    is($LSE->is_open_at($six_am),                   undef,         'LSE not open at 6am');
    is($LSE->is_open_at($six_am_epoch),             undef,         'LSE not open at 6am');
    is($LSE->will_open_after($six_am),              1,             'LSE will open on this day after 6am');
    is($LSE->will_open_after($six_am_epoch),        1,             'LSE will open on this day after 6am');
    is($LSE->seconds_until_open_at($six_am),        60 * 60,       'at 6am, LSE is 1 hour from opening');
    is($LSE->seconds_until_open_at($six_am_epoch),  60 * 60,       'at 6am, LSE is 1 hour from opening');
    is($LSE->seconds_since_open_at($six_am),        undef,         'at 6am, LSE not open yet');
    is($LSE->seconds_since_open_at($six_am_epoch),  undef,         'at 6am, LSE not open yet');
    is($LSE->seconds_until_close_at($six_am),       9.5 * 60 * 60, 'at 6am, 9.5 hours until LSE closes');
    is($LSE->seconds_until_close_at($six_am_epoch), 9.5 * 60 * 60, 'at 6am, 9.5 hours until LSE closes');
    is($LSE->seconds_since_close_at($six_am),       undef,         'at 6am, LSE hasn\'t closed yet');
    is($LSE->seconds_since_close_at($six_am_epoch), undef,         'at 6am, LSE hasn\'t closed yet');

    # after closing time on an LSE trading day:
    my $six_pm       = Date::Utility->new('3-May-13 18:00:00');
    my $six_pm_epoch = $six_pm->epoch;
    is($LSE->is_open_at($six_pm),                   undef,         'LSE not open at 6pm.');
    is($LSE->is_open_at($six_pm_epoch),             undef,         'LSE not open at 6pm.');
    is($LSE->will_open_after($six_pm),              undef,         'LSE will not open on this day after 6pm.');
    is($LSE->will_open_after($six_pm_epoch),        undef,         'LSE will not open on this day after 6pm.');
    is($LSE->seconds_until_open_at($six_pm),        undef,         'at 6pm, LSE has already been open.');
    is($LSE->seconds_until_open_at($six_pm_epoch),  undef,         'at 6pm, LSE has already been open.');
    is($LSE->seconds_since_open_at($six_pm),        11 * 60 * 60,  'at 6pm, LSE opening was 11 hours ago.');
    is($LSE->seconds_since_open_at($six_pm_epoch),  11 * 60 * 60,  'at 6pm, LSE opening was 11 hours ago.');
    is($LSE->seconds_until_close_at($six_pm),       undef,         'at 6pm, LSE has closed.');
    is($LSE->seconds_until_close_at($six_pm_epoch), undef,         'at 6pm, LSE has closed.');
    is($LSE->seconds_since_close_at($six_pm),       2.5 * 60 * 60, 'at 6pm, LSE has been closed for 2.5 hours.');
    is($LSE->seconds_since_close_at($six_pm_epoch), 2.5 * 60 * 60, 'at 6pm, LSE has been closed for 2.5 hours.');

    # LSE holiday:
    my $lse_holiday_epoch = Date::Utility->new('6-May-13 12:00:00')->epoch;
    is($LSE->is_open_at($lse_holiday_epoch),      undef, 'is_open_at LSE not open today at all.');
    is($LSE->will_open_after($lse_holiday_epoch), undef, 'will_open_after LSE not open today at all.');
    is(
        $LSE->seconds_until_open_at($lse_holiday_epoch),
        19 * 60 * 60,
        'LSE not open today so seconds_until_open_at is based on opening time of the next trading day.'
    );
    is($LSE->seconds_since_open_at($lse_holiday_epoch),  undef, 'seconds_since_open_at LSE not open today at all.');
    is($LSE->seconds_until_close_at($lse_holiday_epoch), undef, 'seconds_until_close_at LSE not open today at all.');
    is($LSE->seconds_since_close_at($lse_holiday_epoch), undef, 'seconds_since_close_at LSE not open today at all.');

    # Two session trading stuff:
    my $HKSE = BOM::Market::Exchange->new('HKSE');

    my $lunchbreak_epoch = Date::Utility->new('3-May-13 04:30:00')->epoch;
    is($HKSE->is_open_at($lunchbreak_epoch),            undef,   'HKSE closed for lunch!');
    is($HKSE->will_open_after($lunchbreak_epoch),       1,       'HKSE will open for the afternoon session.');
    is($HKSE->seconds_until_open_at($lunchbreak_epoch), 30 * 60, 'mid lunchbreak, HKSE opens in 1 hour.');
    is($HKSE->seconds_since_open_at($lunchbreak_epoch),  undef, 'seconds since open is undef if market is closed (which includes closed for lunch).');
    is($HKSE->seconds_until_close_at($lunchbreak_epoch), 11400, 'mid lunch, HKSE will close in 3 hours 10 minutes.');
    is($HKSE->seconds_since_close_at($lunchbreak_epoch), 31 * 60, '1 hour into lunch, HKSE closed 31 minutes ago.');

    my $HKSE_close_epoch = Date::Utility->new('3-May-13 07:40:00')->epoch;
    is($HKSE->seconds_since_close_at($HKSE_close_epoch), 0, 'HKSE: seconds since close at close should be zero (as opposed to undef).');

    # DST stuff
    # Europe: last Sunday of March.
    is($LSE->is_open_at(Date::Utility->new('29-Mar-13 07:30:00')->epoch), undef, 'LSE not open at 7:30am GMT during winter.');
    is($LSE->is_open_at(Date::Utility->new('3-Apr-13 07:30:00')->epoch),  1,     'LSE open at 7:30am GMT during summer.');

    # Australia: first Sunday of April.
    # BE CAREFUL: Au "summer" is Northern Hemisphere "winter"!
    my $ASX        = BOM::Market::Exchange->new('ASX');
    my $late_apr_3 = Date::Utility->new('3-Apr-13 23:30:00');
    is($ASX->is_open_at($late_apr_3),                                    1,            'ASX open at 23:30 GMT a day earlier during Aussie "summer"');
    is($ASX->trading_date_for($late_apr_3)->date,                        '2013-04-04', '... and it is trading on the "next" day.');
    is($ASX->is_open_at(Date::Utility->new('5-Apr-13 05:30:00')->epoch), undef,        'ASX not open at 5:30am GMT during Aussie "summer".');
    is($ASX->is_open_at(Date::Utility->new('8-Apr-13 23:30:00')->epoch), undef, 'ASX not open at 23:30 GMT a day earlier during Aussie "winter".');
    is($ASX->is_open_at(Date::Utility->new('8-Apr-13 05:30:00')->epoch), 1,     'ASX open at 5:30am GMT during Aussie "winter".');

    # USA: second Sunday of March.
    my $NYSE = BOM::Market::Exchange->new('NYSE');
    is($NYSE->is_open_at(Date::Utility->new('8-Mar-13 14:00:00')->epoch),  undef, 'NYSE not open at 2pm GMT during winter.');
    is($NYSE->is_open_at(Date::Utility->new('11-Mar-13 14:00:00')->epoch), 1,     'NYSE open at 2pm GMT during summer.');

    is(
        $LSE->opening_on(Date::Utility->new('3-May-13'))->epoch,
        Date::Utility->new('3-May-13 07:00')->epoch,
        'Opening time of LSE on 3-May-13 is 07:00.'
    );
    is(
        $LSE->closing_on(Date::Utility->new('3-May-13'))->epoch,
        Date::Utility->new('3-May-13 15:30')->epoch,
        'Closing time of LSE on 3-May-13 is 14:30.'
    );
    is(
        $LSE->opening_on(Date::Utility->new('8-Feb-13'))->epoch,
        Date::Utility->new('8-Feb-13 08:00')->epoch,
        'Opening time of LSE on 8-Feb-13 is 08:00 (winter time).'
    );
    is(
        $LSE->closing_on(Date::Utility->new('8-Feb-13'))->epoch,
        Date::Utility->new('8-Feb-13 16:30')->epoch,
        'Closing time of LSE on 8-Feb-13 is 16:30 (winter time).'
    );
    is($LSE->opening_on(Date::Utility->new('12-May-13')), undef, 'LSE doesn\'t open on weekend (12-May-13).');

    is(
        $HKSE->opening_on(Date::Utility->new('3-May-13'))->epoch,
        Date::Utility->new('3-May-13 01:30')->epoch,
        '[epoch test] Opening time of HKSE on 3-May-13 is 01:30.'
    );
    ok($HKSE->trading_breaks(Date::Utility->new('3-May-13')), 'HKSE has trading breaks');
    is $HKSE->trading_breaks(Date::Utility->new('3-May-13'))->[0]->[0]->epoch, Date::Utility->new('3-May-13 03:59')->epoch,
        'correct interval open time';
    is $HKSE->trading_breaks(Date::Utility->new('3-May-13'))->[0]->[1]->epoch, Date::Utility->new('3-May-13 05:00')->epoch,
        'correct interval close time';
    is(
        $HKSE->closing_on(Date::Utility->new('3-May-13'))->epoch,
        Date::Utility->new('3-May-13 07:40')->epoch,
        '[epoch test] Closing time of HKSE on 3:-May-13 is 07:40.'
    );

    ok(!$LSE->closes_early_on(Date::Utility->new('23-Dec-13')),   'LSE doesn\'t close early on 23-Dec-10');
    ok($LSE->closes_early_on(Date::Utility->new('24-Dec-13')),    'LSE closes early on 24-Dec-10');
    ok(!$FOREX->closes_early_on(Date::Utility->new('23-Dec-13')), 'FOREX doesn\'t close early on 23-Dec-13');
    is(
        $LSE->closing_on(Date::Utility->new('24-Dec-13'))->epoch,
        Date::Utility->new('24-Dec-13 12:30')->epoch,
        '(Early) closing time of LSE on 24-Dec-13 is 12:30.'
    );

    ok(!$HKSE->opens_late_on(Date::Utility->new('23-Dec-13')), 'HKSE doesn\'t open late on 23-Dec-10');
    ok($HKSE->opens_late_on(Date::Utility->new('24-Dec-10')),  'HKSE opens late on 24-Dec-10');
    is(
        $HKSE->opening_on(Date::Utility->new('24-Dec-10'))->epoch,
        Date::Utility->new('24-Dec-10 02:30')->epoch,
        '(Late) opening time of HKSE on 24-Dec-10 is 02:30.'
    );

    is($HKSE->closing_on(Date::Utility->new('23-Dec-13'))->time_hhmm, '07:40', 'Closing time of HKSE on 23-Dec-10 is 07:40.');

    throws_ok { $LSE->closes_early_on('JUNK') } qr/forgot to load "JUNK"/, 'closes_early_on dies when given a bad date';

    is($LSE->trade_date_before(Date::Utility->new('3-May-13'))->date, '2013-05-02', '2nd May is 1 trading day before 3rd May on FTSE');
    is($LSE->trade_date_before(Date::Utility->new('3-May-13'), {lookback => 2})->date,
        '2013-05-01', '1st May is 2 trading days before 3rd May on FTSE');
    is($LSE->trade_date_before(Date::Utility->new('12-May-13'))->date,
        '2013-05-10', '10th May is 1 trading day before 12th May on FTSE (looking back over weekend)');
    is($LSE->trade_date_before(Date::Utility->new('6-May-13'))->date,
        '2013-05-03', '3rd May is 1 trading day before 6th May on FTSE (4th and 5th are the weekend)');
    is($LSE->trade_date_before(Date::Utility->new('6-May-13'), {lookback => 3})->date,
        '2013-05-01', '1st May is 3 trading days before 6th May on FTSE (4th and 5th are the weekend)');

    is($LSE->holiday_days_between(Date::Utility->new('3-May-13'), Date::Utility->new('7-May-13')), 1, 'See? 6th is a holiday');

    is($LSE->trading_days_between(Date::Utility->new('29-Mar-13'), Date::Utility->new('1-Apr-13')),
        0, 'No trading days between 29th Mar and 1st Apr on LSE');
    is($LSE->trading_days_between(Date::Utility->new('11-May-13'), Date::Utility->new('12-May-13')),
        0, 'No trading days between 11th and 12th May on LSE (over weekend)');
    is($LSE->trading_days_between(Date::Utility->new('4-May-13'), Date::Utility->new('6-May-13')),
        0, 'No trading days between 4th May and 6th May on LSE (over weekend, then holiday on Monday)');
    is($LSE->trading_days_between(Date::Utility->new('10-May-13'), Date::Utility->new('14-May-13')),
        1, '1 trading day between 10th and 14th May on LSE (over weekend, Monday open)');

    is($FOREX->is_OTC, 1,  'FOREX is an OTC exchange.');
    is($LSE->is_OTC,   '', 'LSE is not an OTC exchange.');

    # seconds_of_trading_between:

    # HSI Opens 02:00 hours, closes 04:30 for lunch, reopens at 06:30 after lunch, and closes for the day at 08:00.
    # Thus, opens for 2.5 hours first session, and 1.5 hours the second session for a total of 4 hours per day.
    my @test_data = (
        # Tuesday 10 March 2009 00:00, up to end of the day
        {
            start        => Date::Utility->new(1236643200),
            end          => Date::Utility->new(1236643200 + 86400),
            trading_time => $HKSE_TRADE_DURATION_DAY,
            desc         => 'Trade time : Full Day'
        },
        # Tuesday 10 March 2009 00:00, up to start of lunch break
        {
            start        => Date::Utility->new(1236643200),
            end          => Date::Utility->new(1236643200 + (3 * 3600 + 59 * 60)),
            trading_time => $HKSE_TRADE_DURATION_MORNING,
            desc         => 'Trade time : Lunch Break',
        },
        # Tuesday 10 March 2009 00:00, up to end of lunch break
        {
            start        => Date::Utility->new(1236643200),
            end          => Date::Utility->new(1236643200 + 5 * 3600),
            trading_time => $HKSE_TRADE_DURATION_MORNING,
            desc         => 'Trade Time : End of lunch Break',
        },
        # Tuesday 10 March 2009 02:30, up to end of lunch break
        {
            start        => Date::Utility->new(1236643200 + 1.5 * 3600),
            end          => Date::Utility->new(1236643200 + 5 * 3600),
            trading_time => $HKSE_TRADE_DURATION_MORNING,
            desc         => 'Trade time : Start of trade day to End lunch Break',
        },
        # Tuesday 10 March 2009 00:00, up to 07:00
        {
            start        => Date::Utility->new(1236643200),
            end          => Date::Utility->new(1236643200 + 7 * 3600),
            trading_time => $HKSE_TRADE_DURATION_MORNING + (2 * 3600),
            desc         => 'Trade time : From 00:00 GMT to 07:00 GMT'
        },
        # Tuesday 10 March 2009 00:00, up to Weds 07:00
        {
            start        => Date::Utility->new(1236643200),
            end          => Date::Utility->new(1236643200 + 86400 + 7 * 3600),
            trading_time => $HKSE_TRADE_DURATION_DAY + $HKSE_TRADE_DURATION_MORNING + (2 * 3600),
            desc         => 'Trade time : From 00:00 GMT to next day 07:00 GMT'
        },
        # Tuesday 10 March 2009 03:30, up to Weds 07:00
        {
            start        => Date::Utility->new(1236643200 + 3 * 3600),
            end          => Date::Utility->new(1236643200 + 86400 + 7 * 3600),
            trading_time => (59 * 60) + $HKSE_TRADE_DURATION_EVENING + $HKSE_TRADE_DURATION_MORNING + (2 * 3600),
            desc         => 'Trade time : From 03:00 GMT to next day 07:00 GMT'
        },
        # Tuesday 10 March 2009 03:30, up to Thursday 07:00
        {
            start        => Date::Utility->new(1236643200 + 3 * 3600),
            end          => Date::Utility->new(1236643200 + 2 * 86400 + 7 * 3600),
            trading_time => (59 * 60) + $HKSE_TRADE_DURATION_EVENING + $HKSE_TRADE_DURATION_DAY + $HKSE_TRADE_DURATION_MORNING + (2 * 3600),
            desc         => 'Trade time : From 03:00 GMT to alternate day 07:00 GMT'
        },
        # Tuesday 10 March 2009 03:30, up to Friday 07:00
        {
            start        => Date::Utility->new(1236643200 + 3 * 3600),
            end          => Date::Utility->new(1236643200 + 3 * 86400 + 7 * 3600),
            trading_time => (59 * 60) + $HKSE_TRADE_DURATION_EVENING + (2 * $HKSE_TRADE_DURATION_DAY) + $HKSE_TRADE_DURATION_MORNING + (2 * 3600),
            desc         => 'Trade time : From 03:00 GMT to third day 07:00 GMT'
        },
        # Tuesday 10 March 2009 03:00, up to Saturday 07:00
        {
            start        => Date::Utility->new(1236643200 + 3 * 3600),
            end          => Date::Utility->new(1236643200 + 4 * 86400 + 7 * 3600),
            trading_time => (59 * 60) + $HKSE_TRADE_DURATION_EVENING + (3 * $HKSE_TRADE_DURATION_DAY),
            desc         => 'Trade time : From 03:00 GMT to weekend day 07:00 GMT'
        },
        # Tuesday 10 March 2009 03:00, up to Sunday 07:00
        {
            start        => Date::Utility->new(1236643200 + 3 * 3600),
            end          => Date::Utility->new(1236643200 + 5 * 86400 + 7 * 3600),
            trading_time => (59 * 60) + $HKSE_TRADE_DURATION_EVENING + (3 * $HKSE_TRADE_DURATION_DAY),
            desc         => 'Trade time : From 03:00 GMT to weekend(sunday) day 07:00 GMT'
        },
        # Tuesday 10 March 2009 03:30, up to next Monday 07:00
        {
            start        => Date::Utility->new(1236643200 + 3 * 3600),
            end          => Date::Utility->new(1236643200 + 6 * 86400 + 7 * 3600),
            trading_time => (59 * 60) + $HKSE_TRADE_DURATION_EVENING + (3 * $HKSE_TRADE_DURATION_DAY) + $HKSE_TRADE_DURATION_MORNING + (2 * 3600),
            desc         => 'Trade time : From 03:00 GMT to sixth(monday) day 07:00 GMT'
        },
        # EARLY CLOSE TESTS
        # Thursday 24 December 2009. Market closes early at 04:30.
        {
            start        => Date::Utility->new('24-Dec-09 01:00:00'),
            end          => Date::Utility->new('24-Dec-09 03:00:00'),
            trading_time => (1 * 3600) + (30 * 60),
            desc         => 'Trade time Early Close : Before close',
        },
        {
            start        => Date::Utility->new('24-Dec-09 01:00:00'),
            end          => Date::Utility->new('24-Dec-09 09:00:00'),
            trading_time => $HKSE_TRADE_DURATION_MORNING,
            desc         => 'Trade time Early Close : After Close',
        },
        {
            start        => Date::Utility->new('24-Dec-09 01:30:00'),
            end          => Date::Utility->new('24-Dec-09 08:00:00'),
            trading_time => $HKSE_TRADE_DURATION_MORNING,
            desc         => 'Trade time Early Close : Start of trade day to After Close',
        },
        {
            start        => Date::Utility->new('24-Dec-09 01:30:00'),
            end          => Date::Utility->new('24-Dec-09 05:00:00'),
            trading_time => $HKSE_TRADE_DURATION_MORNING,
            desc         => 'Trade time Early Close : Start of trade day to After Close 2',
        },
        {
            start        => Date::Utility->new('24-Dec-09 01:30:00'),
            end          => Date::Utility->new('24-Dec-09 04:30:00'),
            trading_time => $HKSE_TRADE_DURATION_MORNING,
            desc         => 'Trade time Early Close : Start of trade day to At Close',
        },
        {
            start        => Date::Utility->new('24-Dec-09 01:30:00'),
            end          => Date::Utility->new('24-Dec-09 04:00:00'),
            trading_time => $HKSE_TRADE_DURATION_MORNING,
            desc         => 'Trade time Early Close : Start of trade day to Before Close',
        },
        {
            start        => Date::Utility->new('24-Dec-09 04:30:00'),
            end          => Date::Utility->new('24-Dec-09 08:00:00'),
            trading_time => (0) * 3600,
            desc         => 'Trade time Early Close : Close of trade day to After Close',
        },
        {
            start        => Date::Utility->new('24-Dec-09 05:00:00'),
            end          => Date::Utility->new('24-Dec-09 08:00:00'),
            trading_time => (0) * 3600,
            desc         => 'Trade time Early Close : After Close of trade day to After Close',
        },
        {
            start        => Date::Utility->new('24-Dec-09 06:00:00'),
            end          => Date::Utility->new('24-Dec-09 08:00:00'),
            trading_time => (0) * 3600,
            desc         => 'Trade time Early Close : After Close of trade day to After Close 2',
        },
        {
            start        => Date::Utility->new('24-Dec-09 07:00:00'),
            end          => Date::Utility->new('24-Dec-09 08:00:00'),
            trading_time => (0) * 3600,
            desc         => 'Trade time Early Close : After Close of trade day to After Close 3',
        },
    );
    TEST:
    foreach my $data (@test_data) {
        my $dt                    = $data->{'start'};
        my $dt_end                = $data->{'end'};
        my $expected_trading_time = $data->{'trading_time'};
        my $desc                  = $data->{'desc'};
        is(
            $HKSE->seconds_of_trading_between_epochs($dt->epoch, $dt_end->epoch),
            $expected_trading_time,
            'testing "seconds_of_trading_between_epochs(' . $dt->epoch . ', ' . $dt_end->epoch . ')" on HKSE : [' . $desc . ']',
        );
    }
};

subtest 'regularly_adjusts_trading_hours_on' => sub {
    plan tests => 5;
    my $monday = Date::Utility->new('2013-08-26');
    my $friday = $monday->plus_time_interval('4d');

    note 'It is expected that this long-standing close in forex will not change, so we can use it to verify the implementation.';

    ok(!$FOREX->regularly_adjusts_trading_hours_on($monday), 'FOREX does not regularly adjust trading hours on ' . $monday->day_as_string);
    my $friday_changes = $FOREX->regularly_adjusts_trading_hours_on($friday);
    ok($friday_changes,                       'FOREX regularly adjusts trading hours on ' . $friday->day_as_string);
    ok(exists $friday_changes->{daily_close}, ' changing daily_close');
    is($friday_changes->{daily_close}->{to},   '21h',     '  to 21h after midnight');
    is($friday_changes->{daily_close}->{rule}, 'Fridays', '  by rule "Friday"');
};

subtest 'trading_date_for' => sub {

    plan tests => 8;

    note
        'This assumes that the RANDOM and RANDOM NOCTURNE remain open every day and offset by 12 hours, so we can use them to verify the implementation.';
    my $RANDOM_NOCTURNE = BOM::Market::Exchange->new('RANDOM_NOCTURNE');
    my $today           = Date::Utility->today;

    ok(
        $RANDOM->trading_date_for($today)->is_same_as($RANDOM_NOCTURNE->trading_date_for($today)),
        "Random and Random Nocturne are on the same trading date at midnight today"
    );

    my $yo_am = $today->plus_time_interval('11h');
    ok($RANDOM->trading_date_for($yo_am)->is_same_as($RANDOM_NOCTURNE->trading_date_for($yo_am)), ".. and at 11am this morning");

    my $almost_closed_am = $yo_am->plus_time_interval('59m59s');
    ok($RANDOM->trading_date_for($almost_closed_am)->is_same_as($RANDOM_NOCTURNE->trading_date_for($almost_closed_am)),
        ".. and at a second before noon.");
    my $noon = $today->plus_time_interval('12h');
    ok(!$RANDOM->trading_date_for($noon)->is_same_as($RANDOM_NOCTURNE->trading_date_for($noon)), "At noon, they diverge");
    is($RANDOM->trading_date_for($noon)->days_between($RANDOM_NOCTURNE->trading_date_for($noon)), -1, ".. with Random a day behind Random Nocturne");

    my $yo_pm = $noon->plus_time_interval('11h');
    is($RANDOM->trading_date_for($yo_pm)->days_between($RANDOM_NOCTURNE->trading_date_for($yo_pm)), -1, ".. where it remains at 11pm this evening");

    my $almost_closed_pm = $yo_pm->plus_time_interval('59m59s');
    is($RANDOM->trading_date_for($almost_closed_pm)->days_between($RANDOM_NOCTURNE->trading_date_for($almost_closed_pm)),
        -1, ".. and at a second before midnight.");

    my $tomorrow = $today->plus_time_interval('24h');
    ok(
        $RANDOM->trading_date_for($tomorrow)->is_same_as($RANDOM_NOCTURNE->trading_date_for($tomorrow)),
        "Then Random and Random Nocturne are on back the same trading date at midnight tomorrow"
    );
};

subtest 'trading_date_can_differ' => sub {

    my $never_differs = BOM::Market::Exchange->new('NYSE');
    ok(!$never_differs->trading_date_can_differ, $never_differs->symbol . ' never trades on a different day than the UTC calendar day.');
    my $always_differs = BOM::Market::Exchange->new('RANDOM_NOCTURNE');
    ok($always_differs->trading_date_can_differ, $always_differs->symbol . ' always trades on a different day than the UTC calendar day.');
    my $sometimes_differs = BOM::Market::Exchange->new('ASX');
    ok($sometimes_differs->trading_date_can_differ, $sometimes_differs->symbol . ' sometimes trades on a different day than the UTC calendar day.');

};

subtest 'regular_trading_day_after' => sub {
    my $exchange = BOM::Market::Exchange->new('FOREX');
    lives_ok {
        my $weekend     = Date::Utility->new('2014-03-29');
        my $regular_day = $exchange->regular_trading_day_after($weekend);
        is($regular_day->date_yyyymmdd, '2014-03-31', 'correct regular trading day after weekend');
        my $new_year = Date::Utility->new('2014-01-01');
        $regular_day = $exchange->regular_trading_day_after($new_year);
        is($regular_day->date_yyyymmdd, '2014-01-02', 'correct regular trading day after New Year');
    }
    'test regular trading day on weekend and exchange holiday';
};

subtest 'get exchange settlement time' => sub {
    my $testing_date = Date::Utility->new(1426564197);
    lives_ok {
        is($LSE->settlement_on($testing_date)->epoch,             '1426620600', 'correct settlement time for LSE');
        is($FSE->settlement_on($testing_date)->epoch,             '1426620600', 'correct settlement time for FSE');
        is($FOREX->settlement_on($testing_date)->epoch,           '1426636799', 'correct settlement time for FOREX');
        is($RANDOM->settlement_on($testing_date)->epoch,          '1426636799', 'correct settlement time for RANDOM');
        is($RANDOM_NOCTURNE->settlement_on($testing_date)->epoch, '1426593599', 'correct settlement time for RANDOM NOCTURNE');
        is($ASX->settlement_on($testing_date)->epoch,             '1426579200', 'correct settlement time for ASX');
        is($NYSE->settlement_on($testing_date)->epoch,            '1426633199', 'correct settlement time for NYSE');
        is($HKSE->settlement_on($testing_date)->epoch,            '1426588800', 'correct settlement time for HKSE');
        is($ISE->settlement_on($testing_date)->epoch,             '1426631400', 'correct settlement time for ISE');

    }
    'test regular settlement time ';
};

subtest 'trading period' => sub {
    my $ex           = BOM::Market::Exchange->new('HKSE');
    my $trading_date = Date::Utility->new('15-Jul-2015');
    lives_ok {
        my $p = $ex->trading_period($trading_date);
        # daily_open       => '1h30m',
        # trading_breaks   => [['3h59m', '5h00m']],
        # daily_close      => '7h40m',
        my $expected = [
            {open  => Time::Local::timegm(0, 30, 1, 15, 6, 115),
             close => Time::Local::timegm(0, 59, 3, 15, 6, 115)},
            {open  => Time::Local::timegm(0, 0, 5, 15, 6, 115),
             close => Time::Local::timegm(0, 40, 7, 15, 6, 115)},
        ];
        is_deeply $p, $expected, 'two periods';
    }
    'trading period for HKSE';
    $ex = BOM::Market::Exchange->new('FOREX');
    lives_ok {
        my $p = $ex->trading_period($trading_date);
        # daily_open: 0s
        # daily_close: 23h59m59s
        my $expected = [
            {open  => Time::Local::timegm(0, 0, 0, 15, 6, 115),
             close => Time::Local::timegm(59, 59, 23, 15, 6, 115)},
        ];
        is_deeply $p, $expected, 'one period';
    }
    'trading period for HKSE';
};

done_testing;

1;
