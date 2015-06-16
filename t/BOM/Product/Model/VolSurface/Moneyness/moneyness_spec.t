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
    'exchange',
    {
        symbol => 'BM',
        date   => Date::Utility->new,
    });

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
        parameterization => undef,
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

subtest fetching_volsurface_data_from_couch => sub {
    plan tests => 4;

    my $fake_parameterization = {
        values            => {something => 0.1},
        calibration_error => 100,
        date              => '12-Nov-12'
    };
    my $fake_surface = {1 => {smile => {100 => 0.1}}};
    my $fake_date = Date::Utility->new('12-Sep-12');

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol           => 'IBEX35',
            parameterization => $fake_parameterization,
            surface          => $fake_surface,
            recorded_date    => $fake_date,
        });

    my $u = BOM::Market::Underlying->new('IBEX35');
    my $vs = BOM::MarketData::VolSurface::Moneyness->new(underlying => $u);

    is_deeply($vs->parameterization, $fake_parameterization, 'parameterization is fetched correctly');
    is_deeply($vs->surface,          $fake_surface,          'surface is fetched correctly');
    is($vs->recorded_date->epoch, $fake_date->epoch, 'surface recorded_date is fetched correctly');
    is($vs->calibration_error, $fake_parameterization->{calibration_error}, 'calibration fit is fetched correctly');
};

subtest saving_volsurface_data_with_old_parameterization => sub {
    plan tests => 4;

    my $fake_surface = {1 => {smile => {100 => 0.2}}};
    my $fake_date    = Date::Utility->new;
    my $u            = BOM::Market::Underlying->new('IBEX35');
    my $ibex         = BOM::MarketData::VolSurface::Moneyness->new({
        underlying    => $u,
        surface       => $fake_surface,
        recorded_date => $fake_date
    });
    my $existing_parameterization = $ibex->parameterization;
    lives_ok { $ibex->save } 'saves surface data with new recorded date';
    my $new_ibex = BOM::MarketData::VolSurface::Moneyness->new(underlying => $u);
    is_deeply($new_ibex->surface, $fake_surface, 'is surface data updated');
    is($new_ibex->recorded_date->epoch, $fake_date->epoch, 'is recorded date updated');
    is_deeply($new_ibex->calibration_error, $existing_parameterization->{calibration_error}, 'calibration fit stays unchanged');
};

subtest saving_parameterization_with_old_volsurface_data => sub {
    plan tests => 4;

    my $fake_parameterization = {
        values => {
            something => 0.1,
            else      => 0.2
        },
        calibration_error => 100,
        date              => '12-Nov-11'
    };
    my $u    = BOM::Market::Underlying->new('IBEX35');
    my $ibex = BOM::MarketData::VolSurface::Moneyness->new({
        underlying       => $u,
        parameterization => $fake_parameterization
    });
    my $existing_surface_data          = $ibex->surface;
    my $existing_surface_recorded_date = $ibex->recorded_date;
    lives_ok { $ibex->save } 'saves parameterization with existing volsurface data';
    my $new_ibex = BOM::MarketData::VolSurface::Moneyness->new(underlying => $u);
    is_deeply($new_ibex->parameterization, $fake_parameterization, 'parameterization updated');
    is($new_ibex->recorded_date->epoch, $existing_surface_recorded_date->epoch, 'surface recorded date stays unchanged');
    is_deeply($new_ibex->surface, $existing_surface_data, 'surface data stays unchanged');
};

subtest saving_new_parameterization_after_recompute_parameterization => sub {
    plan tests => 4;

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'IBEX35',
            recorded_date => Date::Utility->new,
        });

    my $u                              = BOM::Market::Underlying->new('IBEX35');
    my $ibex                           = BOM::MarketData::VolSurface::Moneyness->new(underlying => $u);
    my $existing_parameterization      = $ibex->parameterization->{values};
    my $existing_surface_data          = $ibex->surface;
    my $existing_surface_recorded_date = $ibex->recorded_date;
    lives_ok {
        $ibex->compute_parameterization;
        $ibex->save;
        my $new_ibex = BOM::MarketData::VolSurface::Moneyness->new(underlying => $u);
        isnt($new_ibex->parameterization->{values}->{atmvolshort}, $existing_parameterization->{atmvolshort}, 'new parameterization updated');
        is($new_ibex->recorded_date->epoch, $existing_surface_recorded_date->epoch, 'surface recorded date stays unchange');
        is_deeply($new_ibex->surface, $existing_surface_data, 'surface data stays unchange');
    }
    'computes new parameterization';
};

done_testing;
