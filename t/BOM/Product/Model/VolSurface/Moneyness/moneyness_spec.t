use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Runtime qw(:normal);
use BOM::MarketData::VolSurface::Moneyness;
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Market::Underlying;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Date::Utility;

initialize_realtime_ticks_db;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'EUR',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'index',
    {
        symbol => 'IBEX35',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_moneyness',
    {
        symbol           => 'IBEX35',
        recorded_date    => Date::Utility->new('12-Sep-12'),
    });

subtest creates_moneyness_object => sub {
    plan tests => 5;
    lives_ok { BOM::MarketData::VolSurface::Moneyness->new(symbol     => 'IBEX35') } 'creates moneyness surface with symbol hash';
    lives_ok { BOM::MarketData::VolSurface::Moneyness->new(underlying => BOM::Market::Underlying->new('IBEX35')) }
    'creates moneyness surface with underlying hash when underlying isa B::FM::Underlying';
    throws_ok { BOM::MarketData::VolSurface::Moneyness->new(underlying => 'IBEX35') } qr/Attribute \(symbol\) is required/,
        'throws exception if underlying is not B::FM::Underlying';
    throws_ok {
        BOM::MarketData::VolSurface::Moneyness->new(
            underlying    => BOM::Market::Underlying->new('IBEX35'),
            recorded_date => '12-Sep-12'
        );
    }
    qr/Must pass both "surface" and "recorded_date" if passing either/, 'throws exception if only pass in recorded_date';
    throws_ok {
        BOM::MarketData::VolSurface::Moneyness->new(
            underlying => BOM::Market::Underlying->new('IBEX35'),
            surface    => {});
    }
    qr/Must pass both "surface" and "recorded_date" if passing either/, 'throws exception if only pass in surface';
};

subtest fetching_volsurface_data_from_db => sub {
    plan tests => 2;

    my $fake_surface = {1 => {smile => {100 => 0.1}}};
    my $fake_date = Date::Utility->new('12-Sep-12');

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol           => 'IBEX35',
            surface          => $fake_surface,
            recorded_date    => $fake_date,
        });

    my $u = BOM::Market::Underlying->new('IBEX35');
    my $vs = BOM::MarketData::VolSurface::Moneyness->new(underlying => $u);

    is_deeply($vs->surface,          $fake_surface,          'surface is fetched correctly');
    is($vs->recorded_date->epoch, $fake_date->epoch, 'surface recorded_date is fetched correctly');
};

done_testing;
