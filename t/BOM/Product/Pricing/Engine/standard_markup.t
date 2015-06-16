use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use Date::Utility;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );
use BOM::Product::ContractFactory qw( produce_contract );

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'FOREX',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/AUD NZD USD JPY EUR CAD GBP NOK/);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new,
    })
    for qw(frxAUDNZD frxAUDUSD frxAUDJPY frxUSDJPY frxEURCAD
    frxGBPNOK frxNZDUSD frxEURUSD frxUSDCAD frxGBPUSD frxUSDNOK);

my @cases = ({
        symbol                     => 'frxAUDNZD',
        time                       => '00h30',
        duration                   => '10m',
        bet_type                   => 'INTRADD',
        expected_adjustment_after  => 390,
        expected_adjustment_before => 0,
    },
    {
        symbol                     => 'frxAUDJPY',
        time                       => '03h50',
        duration                   => '15m',
        bet_type                   => 'INTRADU',
        expected_adjustment_after  => 0,
        expected_adjustment_before => 0,
    },
    {
        symbol                     => 'frxUSDJPY',
        time                       => '16h50',
        duration                   => '26m',
        bet_type                   => 'INTRADU',
        expected_adjustment_after  => 0,
        expected_adjustment_before => 850,
    },
    {
        symbol                     => 'frxEURCAD',
        time                       => '00h50',
        duration                   => '5m',
        bet_type                   => 'INTRADU',
        expected_adjustment_after  => 560,
        expected_adjustment_before => 380,
    },
    {
        symbol                     => 'frxGBPNOK',
        time                       => '00h00',
        duration                   => '5m',
        bet_type                   => 'INTRADU',
        expected_adjustment_after  => 0,
        expected_adjustment_before => 0,
    },
);

for my $case (@cases) {
    my $underlying = BOM::Market::Underlying->new($case->{symbol});
    my $date_after = $underlying->trade_date_after(Date::Utility->new('9-Mar-14'));
    $date_after = Date::Utility->new($date_after->date_ddmmmyy . " " . $case->{time});
    my $date_before = $underlying->trade_date_before(Date::Utility->new('9-Mar-14'));
    $date_before = Date::Utility->new($date_before->date_ddmmmyy . " " . $case->{time});
    for ({
            date => $date_after,
            adj  => $case->{expected_adjustment_after},
        },
        {
            date => $date_before,
            adj  => $case->{expected_adjustment_before},
        })
    {
        my $contract = produce_contract({
                currency   => 'USD',
                underlying => BOM::Market::Underlying->new({
                        symbol   => $case->{symbol},
                        for_date => $_->{date},
                    },
                ),
                date_start   => $_->{date},
                date_pricing => $_->{date}->minus_time_interval('10m'),
                duration     => Time::Duration::Concise::Localize->new(interval => $case->{duration})->as_concise_string,
                barrier      => 'S0P',
                bet_type     => $case->{bet_type},
                current_spot => 1,
            },
        );
        is sprintf("%.0f", $contract->ask_probability->peek_amount('spot_seasonality_markup') * 1e4), $_->{adj},
            "expected adjustment for $case->{symbol} contract";
    }
}

done_testing;
