use Test::MockTime qw( restore_time set_absolute_time );
use Test::Most;
use Test::MockModule;

use BOM::MarketDataAutoUpdater::Indices;
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);

my $fake_date = Date::Utility->new('2012-12-12 15:55:55');
set_absolute_time($fake_date->epoch);

my @otc_symbols = (
    'OTC_AEX', 'OTC_AS51', 'OTC_DJI',  'OTC_FCHI', 'OTC_FTSE', 'OTC_GDAXI', 'OTC_HSI',   'OTC_N225',
    'OTC_NDX', 'OTC_SPC',  'OTC_SSMI', 'OTC_SX5E', 'OTC_MID',  'OTC_XIN9I', 'OTC_HSCEI', 'OTC_RTY'
);
@otc_symbols = sort @otc_symbols;

my $symbols_to_update = \@otc_symbols;

BOM::Test::Data::Utility::FeedTestDatabase::create_realtime_tick({
        underlying => $_,
        epoch      => $fake_date->epoch,
        quote      => 100
    }) for @$symbols_to_update;

initialize_realtime_ticks_db;

my $au = BOM::MarketDataAutoUpdater::Indices->new(
    filename     => 'dummy',
    update_for   => 'all',
    root_path    => 'root_path',
    input_market => 'indices'
);

is $au->filename,     'dummy',     'filename';
is $au->update_for,   'all',       'update_for';
is $au->root_path,    'root_path', 'root_path';
is $au->input_market, 'indices',   'input_market';

is_deeply($au->symbols_to_update, $symbols_to_update, 'symbols_to_update matches');

my $bloomberg_symbol_mapping = {
    'AEX'   => 'OTC_AEX',
    'AS51'  => 'OTC_AS51',
    'CAC'   => 'OTC_FCHI',
    'DAX'   => 'OTC_GDAXI',
    'HSI'   => 'OTC_HSI',
    'INDU'  => 'OTC_DJI',
    'NDX'   => 'OTC_NDX',
    'NKY'   => 'OTC_N225',
    'SMI'   => 'OTC_SSMI',
    'SPX'   => 'OTC_SPC',
    'SX5E'  => 'OTC_SX5E',
    'UKX'   => 'OTC_FTSE',
    'MID'   => 'OTC_MID',
    'XIN9I' => 'OTC_XIN9I',
    'HSCEI' => 'OTC_HSCEI',
    'RTY'   => 'OTC_RTY'
};

is_deeply($au->bloomberg_symbol_mapping, $bloomberg_symbol_mapping, 'bloomberg_symbol_mapping matches');

my $surface_data = {
    AEX => {
        volupdate_time => $fake_date,
        '1'            => {
            'spread' => {50 => '0.14'},
            'smile'  => {50 => '0.14'}}
    },
    CAC => {
        volupdate_time => $fake_date,
        '7'            => {
            'spread' => {50 => '0.14'},
            'smile'  => {50 => '0.14'}}
    },
    DAX => {
        volupdate_time => $fake_date,
        '1'            => {
            'spread' => {50 => '0.14'},
            'smile'  => {50 => '0.14'}}
    },

    Dummy => {'7' => {'smile' => {}}}};

my $mocked_bvol = Test::MockModule->new('Bloomberg::VolSurfaces::BVOL');
$mocked_bvol->mock('parser' => sub { return $surface_data });

lives_ok { $au->run } 'run without dying';

restore_time();
done_testing;
