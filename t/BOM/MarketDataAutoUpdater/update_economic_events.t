use Test::MockTime qw( restore_time set_absolute_time );
use Test::Most;
use Test::MockModule;
use File::Basename qw(dirname);
use Path::Tiny;
use BOM::MarketDataAutoUpdater::UpdateEconomicEvents;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

my $fake_date = Date::Utility->new('2017-08-31 15:55:55');
set_absolute_time($fake_date->epoch);

Path::Tiny::path("/feed/economic_events/" . $fake_date->date_yyyymmdd)->touchpath;

my $au       = BOM::MarketDataAutoUpdater::UpdateEconomicEvents->new();
my $data_dir = dirname(__FILE__) . '/../../data/bbdl/economic_events';

my $mocked_file = Test::MockModule->new('Bloomberg::FileDownloader');
$mocked_file->mock('grab_files' => sub { return "$data_dir/ee_0000.csv" });

my $dummy_events = {
    'event_name'    => 'dummy',
    'source'        => 'dummy',
    'symbol'        => 'USD',
    'binary_ticker' => 'dummy',
    'release_date'  => 1505120400,
    'forecast'      => 'N.A.',
    'actual'        => '.6',
    'impact'        => '2',
    'previous'      => '.600000',
    'unit'          => ''
};

my $mocked_factory = Test::MockModule->new('ForexFactory');
$mocked_factory->mock('extract_economic_events' => sub { return [$dummy_events] });

our $stats_gauge;
my $mocked = Test::MockModule->new('BOM::MarketDataAutoUpdater::UpdateEconomicEvents');
$mocked->mock('stats_gauge' => sub { $stats_gauge = \@_ });

lives_ok { $au->run } 'run without dying';

is_deeply($stats_gauge, ['economic_events_saved', 4], 'economic_events_saved');

is_deeply($au->get_events_from_forex_factory, [$dummy_events, $dummy_events, $dummy_events], 'get_events_from_forex_factory data matches');

restore_time();
done_testing;
