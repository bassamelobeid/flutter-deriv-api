use Test::Most qw(-Test::Deep);
use Test::FailWarnings;
use Test::MockObject::Extends;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Runtime qw(:normal);
use Date::Utility;
use BOM::Market::Underlying;
use BOM::MarketData::VolSurface::Moneyness;
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'SPC',
        recorded_date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'SPC',
        date   => Date::Utility->new,
    });

my $recorded_date = Date::Utility->new('12-Jun-11');
my $underlying    = BOM::Market::Underlying->new('SPC');
my $surface       = {
    7 => {
        smile => {
            30    => 0.9044,
            40    => 0.8636,
            60    => 0.6713,
            80    => 0.4864,
            90    => 0.3348,
            95    => 0.2444,
            97.5  => 0.2017,
            100   => 0.1639,
            102.5 => 0.136,
            105   => 0.1501,
            110   => 0.2011,
            120   => 0.2926,
            150   => 0.408,
        },
        vol_spread => {100 => 0.1},
    },
    14 => {
        smile => {
            90  => 0.4,
            95  => 0.3,
            100 => 0.2,
            105 => 0.4,
            110 => 0.5
        },
        vol_spread => {100 => 0.1}
    },
};

my $v = BOM::MarketData::VolSurface::Moneyness->new(
    underlying     => $underlying,
    recorded_date  => $recorded_date,
    surface        => $surface,
    spot_reference => 101,
);

subtest "can get volatility for strike, delta, and moneyness" => sub {
    plan tests => 3;
    lives_ok { $v->get_volatility({days => 7, delta     => 25}) } "can get_volatility for delta point on a moneyness surface";
    lives_ok { $v->get_volatility({days => 7, moneyness => 104}) } "can get_volatility for moneyness point on a moneyness surface";
    lives_ok { $v->get_volatility({days => 7, strike    => 304.68}) } "can get_volatility for strike point on a moneyness surface";
};

subtest "cannot get volatility when underlying spot is undef" => sub {
    plan tests => 4;
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol         => 'SPC',
            spot_reference => 101,
            recorded_date  => Date::Utility->new,
        });
    throws_ok {
        BOM::MarketData::VolSurface::Moneyness->new(
            underlying     => $underlying,
            recorded_date  => $recorded_date,
            surface        => $surface,
            spot_reference => undef,
        );
    }
    qr/Attribute \(spot_reference\) does not pass the type constraint/, 'cannot get_volatility when spot for underlying is undef';
    my $v_new2;
    lives_ok {
        $v_new2 = BOM::MarketData::VolSurface::Moneyness->new(
            underlying    => $underlying,
            recorded_date => $recorded_date,
            surface       => $surface,
        );
    }
    'creates moneyness surface without spot reference';
    is($v_new2->spot_reference, 101, 'spot reference retrieved from database');
    lives_ok { $v_new2->get_volatility({days => 7, delta => 35}) } "can get_volatility";
};

subtest "cannot get volatility for anything other than [strike, delta, moneyness]" => sub {
    plan tests => 1;
    throws_ok { $v->get_volatility({days => 7, garbage => 25}) } qr/exactly one of/i,
        "cannot get_volatility for garbage point on a moneyness surface";
};

subtest "uses smile of the smallest available term structure when we need price for that" => sub {
    plan tests => 1;
    is(
        $v->get_volatility({
                moneyness => 100,
                days      => 1
            }
        ),
        0.1639,
        "correct volatility value"
    );
};

done_testing;
