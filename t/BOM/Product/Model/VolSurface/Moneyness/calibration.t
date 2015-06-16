use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Runtime qw(:normal);
use BOM::MarketData::VolSurface::Moneyness;

use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);

initialize_realtime_ticks_db();

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/FSE EURONEXT SES/);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_moneyness',
    {
        recorded_date => Date::Utility->new,
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
        symbol => 'GDAXI',
        date   => Date::Utility->new,
    });

my $vol_with_surface;
subtest test_calibration_param_logic_for_surface_without_param => sub {
    plan tests => 6;
    my $moneyness;
    lives_ok { $moneyness = BOM::MarketData::VolSurface::Moneyness->new(symbol => 'GDAXI') } 'can create moneyness surface object';
    my @default_param_names = qw(
        atmvolshort
        atmvol1year
        atmvolLong
        atmWingL
        atmWingR
        skewshort
        skew1year
        skewlong
        skewwingL
        skewwingR
        kurtosisshort
        kurtosislong
        kurtosisgrowth
    );
    is_deeply($moneyness->calibration_param_names, \@default_param_names, 'param names have not changed');
    lives_ok { $moneyness->calibrated_surface } 'can get calibrated surface with initial params when parameterization is undef';
    lives_ok { $moneyness->calibration_error } 'can get calibration fit';
    isa_ok($moneyness->compute_parameterization, 'HASH');
    lives_ok { $vol_with_surface = $moneyness->get_volatility({moneyness => 100, days => 7}) } 'can get volatility with surface';
};

my $default = BOM::Platform::Runtime->instance->app_config->quants->underlyings->price_with_parameterized_surface;
subtest test_calibration_for_surface_with_param => sub {
    plan tests => 5;
    my $params = {
        atmvolshort    => 0.1,
        atmvol1year    => 0.1,
        atmvolLong     => 0.1,
        atmWingL       => 0.2,
        atmWingR       => 0.1,
        skewshort      => 0.1,
        skew1year      => 0.1,
        skewlong       => 0.1,
        skewwingL      => 0.2,
        skewwingR      => 0.1,
        kurtosisshort  => 0.1,
        kurtosislong   => 0.1,
        kurtosisgrowth => 0.1,
    };

    my $moneyness_with_param = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol           => 'GDAXI',
            parameterization => {
                values            => $params,
                calibration_error => 10,
            },
            recorded_date => Date::Utility->new,
        });

    is(BOM::Platform::Runtime->instance->app_config->quants->features->enable_parameterized_surface, 1, 'default to true');
    my $new_list = '{"indices" : {"europe_africa" : ["GDAXI"]}}';
    ok(BOM::Platform::Runtime->instance->app_config->quants->underlyings->price_with_parameterized_surface($new_list),
        'adds GDAXI in price_with_parameterized_surface list');
    is_deeply($moneyness_with_param->parameterization->{values}, $params, 'get correct params from couch');
    my $vol_with_param;
    lives_ok { $vol_with_param = $moneyness_with_param->get_volatility({moneyness => 100, days => 7}) } 'can get volatility with param';
    isnt($vol_with_surface, $vol_with_param, 'slightly different vol');
};

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_moneyness',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new,
    }) for qw/AEX STI/;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'SGD',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'index',
    {
        symbol => 'AEX',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'index',
    {
        symbol => 'STI',
        date   => Date::Utility->new,
    });

subtest 'price with parameterized surface switch' => sub {
    lives_ok {
        my $list = '{"indices" : { "europe_africa" : "all"}}';
        ok(BOM::Platform::Runtime->instance->app_config->quants->underlyings->price_with_parameterized_surface($list),
            'adds GDAXI in price_with_parameterized_surface list');
        my $aex = BOM::MarketData::VolSurface::Moneyness->new(symbol => 'AEX');
        ok $aex->price_with_parameterized_surface, 'AEX is in europe_africa submarket';
        my $sti = BOM::MarketData::VolSurface::Moneyness->new(symbol => 'STI');
        ok !$sti->price_with_parameterized_surface, 'STI is in asia oceania, so it is not enabled';
    }
    'all submarket test';

    lives_ok {
        my $list = '{"indices" : { "europe_africa" : ["GDAXI","AEX"]}}';
        ok(BOM::Platform::Runtime->instance->app_config->quants->underlyings->price_with_parameterized_surface($list),
            'adds GDAXI in price_with_parameterized_surface list');
        my $aex = BOM::MarketData::VolSurface::Moneyness->new(symbol => 'AEX');
        ok $aex->price_with_parameterized_surface, 'AEX is in europe_africa submarket';
        my $gdaxi = BOM::MarketData::VolSurface::Moneyness->new(symbol => 'GDAXI');
        ok $gdaxi->price_with_parameterized_surface, 'GDAXI is in europe_africa submarket';
        my $sti = BOM::MarketData::VolSurface::Moneyness->new(symbol => 'STI');
        ok !$sti->price_with_parameterized_surface, 'STI is in asia oceania, so it is not enabled';
    }
    'underlying specific';
};

BOM::Platform::Runtime->instance->app_config->quants->underlyings->price_with_parameterized_surface($default);
is_deeply(BOM::Platform::Runtime->instance->app_config->quants->underlyings->price_with_parameterized_surface, $default, 'reverts to default');

done_testing;
