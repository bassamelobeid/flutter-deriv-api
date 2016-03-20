use Test::Most qw(-Test::Deep);
use Scalar::Util qw( looks_like_number );
use Test::MockObject::Extends;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Runtime qw(:normal);
use Date::Utility;
use BOM::Market::Underlying;
use BOM::MarketData::VolSurface::Moneyness;
use BOM::Market::UnderlyingDB;
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'HSI',
        recorded_date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/HKD USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'SPC',
        date   => Date::Utility->new,
    });

subtest clone => sub {
    plan tests => 5;
    my $now = Date::Utility->new('2012-06-14 08:00:00');
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch,
        quote      => 100,
        underlying => 'HSI'
    });
    my $underlying = BOM::Market::Underlying->new('HSI');
    my $surface    = {
        'ON' => {smile => {100 => 0.1}},
        '1W' => {smile => {100 => 0.2}}};
    my $volsurface = BOM::MarketData::VolSurface::Moneyness->new(
        underlying     => $underlying,
        spot_reference => 100,
        surface        => $surface,
        recorded_date  => $now,
    );

    lives_ok { $volsurface->clone } 'Can clone BOM::MarketData::VolSurface::Moneyness';
    my $clone;
    lives_ok { $clone = $volsurface->clone({surface => {ON => {smile => {100 => 0.5}}}}) };
    isa_ok($clone, 'BOM::MarketData::VolSurface::Moneyness');
    is($clone->surface->{1}->{smile}->{100}, 0.5, 'can change attribute value when clone');

    my $spot_reference = 100 - 10 * $underlying->pip_size;
    $clone = $volsurface->clone({spot_reference => $spot_reference});

    cmp_ok($clone->spot_reference, '==', $spot_reference, 'Adjusted spot ref preserved through clone.');
};

subtest 'get available strikes on surface' => sub {
    plan tests => 2;
    my $underlying = BOM::Market::Underlying->new('HSI');
    my $surface    = {
        'ON' => {smile => {100 => 0.1}},
        '1W' => {smile => {100 => 0.2}}};
    my $volsurface = BOM::MarketData::VolSurface::Moneyness->new(
        underlying     => $underlying,
        spot_reference => 100,
        surface        => $surface,
        recorded_date  => Date::Utility->new('2012-06-14 08:00:00'),
    );
    my $moneyness_points;
    lives_ok { $moneyness_points = $volsurface->moneynesses } 'can call moneynesses';
    is_deeply($moneyness_points, [100], 'get correct value for moneyness points');
};

subtest 'get surface spot reference' => sub {
    plan tests => 3;
    my $underlying = BOM::Market::Underlying->new('HSI');
    my $date       = Date::Utility->new('2012-06-14 08:00:00');

    my $surface = {
        'ON' => {smile => {100 => 0.1}},
        '1W' => {smile => {100 => 0.2}},
    };
    my $volsurface = BOM::MarketData::VolSurface::Moneyness->new(
        underlying     => $underlying,
        surface        => $surface,
        recorded_date  => $date,
        spot_reference => 100,
    );

    my $spot;
    lives_ok { $spot = $volsurface->spot_reference } 'can call spot reference of the surface';
    is($spot, 100, 'Got what I put in');
    ok(looks_like_number($spot), 'spot is a number');
};

subtest _convert_strike_to_delta => sub {
    plan tests => 3;

    my $underlying = BOM::Market::Underlying->new('SPC');

    my $fake_data = {
        epoch => Date::Utility->new('2012-06-14 08:00:00')->epoch,
        quote => 100,
    };

    $underlying->set_combined_realtime($fake_data);

    my $surface = {
        'ON' => {smile => {100 => 0.1}},
        '1W' => {smile => {100 => 0.2}}};
    my $volsurface = BOM::MarketData::VolSurface::Moneyness->new(
        underlying     => $underlying,
        surface        => $surface,
        recorded_date  => Date::Utility->new('2012-06-14 08:00:00'),
        spot_reference => 100,
    );
    my $args = {
        strike => 100,
        days   => 7,
        vol    => 0.11
    };
    my $delta;
    lives_ok { $delta = $volsurface->_convert_strike_to_delta($args) } 'can convert strike to delta';
    ok(looks_like_number($delta), 'delta is a number');
    cmp_ok($delta, '<=', 100, 'delta is <= 100');
};

done_testing;
