use strict;
use warnings;

use Storable qw(dclone);
use Test::MockObject::Extends;
use Test::Exception;
use File::Basename qw( dirname );
use File::Temp;
use Test::Deep     qw( cmp_deeply );
use Test::MockTime qw( restore_time set_absolute_time );
use Test::More     qw( no_plan );
use Test::MockModule;
use File::Spec;
use Quant::Framework::VolSurface::Utils qw(NY1700_rollover_date_on);

$ENV{QUANT_FRAMEWORK_HOLIDAY_CACHE} = 0;
use constant MAX_ALLOWED_AGE => 4 * 60 * 60;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::MarketDataAutoUpdater::Forex;
use BOM::MarketData qw(create_underlying create_underlying_db);
use BOM::MarketData::Types;

# Prep:
my $fake_date = Date::Utility->new('2012-08-13 15:55:55');
set_absolute_time($fake_date->epoch);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/JPY USD GBP INR AUD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'holiday',
    {
        recorded_date => $fake_date,
        calendar      => {
            '2013-01-01' => {
                'New Year' => ['FOREX'],
            }
        },
    });
my @symbol_list = qw(frxAUDJPY frxGBPJPY frxUSDJPY frxGBPINR);

Quant::Framework::Utils::Test::create_doc(
    'volsurface_delta',
    {
        underlying       => create_underlying($_),
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
        recorded_date    => Date::Utility->new,
    }) for @symbol_list;

BOM::Test::Data::Utility::FeedTestDatabase::create_realtime_tick({
        underlying => $_,
        epoch      => $fake_date->epoch,
        quote      => 100
    }) for @symbol_list;

initialize_realtime_ticks_db;

subtest 'Basics.' => sub {
    my $auf = BOM::MarketDataAutoUpdater::Forex->new(
        update_for => 'all',
        source     => 'BBDL'
    );
    my @symbols = @{$auf->symbols_to_update};

    ok(scalar(@symbols), 'symbols_to_update is non-empty by default.');
    cmp_ok(scalar(@symbols), '==', (grep { /^frx/ } @symbols), 'All symbols_to_udpate are FX.');
};

my $data = {
    7 => {
        smile => {
            25 => 0.12 + rand(0.01),
            50 => 0.12,
            75 => 0.11
        },
        vol_spread => {50 => 0.1}
    },
    14 => {
        smile => {
            25 => 0.12,
            50 => 0.12,
            75 => 0.11
        },
        vol_spread => {50 => 0.1}
    },
};

my $usdjpy = create_underlying('frxUSDJPY');

use Data::Dumper; $Data::Dumper::Maxdepth=2;
subtest 'surfaces_from_file' => sub {
my $fake_surface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        underlying    => $usdjpy,
        recorded_date => Date::Utility->new(time),
        surface       => $data,
    });

    my $mocked_bbdl = Test::MockModule->new('Bloomberg::VolSurfaces::BBDL');
    $mocked_bbdl->mock('parser' => sub { return {frxUSDJPY => $fake_surface} });

    my $auf = BOM::MarketDataAutoUpdater::Forex->new(
        update_for => 'all',
        source     => 'BBDL'
    );
    my $abc = $auf->surfaces_from_file;
    ok $abc, "$abc";
    note Dumper( $abc  );
   #   my $mocked_bvol = Test::MockModule->new('Bloomberg::VolSurfaces::BVOL');
   # $mocked_bbdl->mock('parser' => sub { return {frxUSDJPY => $fake_surface} });

   # $auf = BOM::MarketDataAutoUpdater::Forex->new(
   #     update_for => 'all',
   #     source     => 'BVOL'
   # );
   # note explain $auf->surfaces_from_file;
};

restore_time();
