use Test::Most;
use File::Basename qw(dirname);
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Test::MockTime                               qw( restore_time set_absolute_time );
use BOM::MarketDataAutoUpdater::InterestRates;

my $fake_date = Date::Utility->new('2022-12-12 15:55:55');
set_absolute_time($fake_date->epoch);
my $data_dir    = dirname(__FILE__) . '/../../data/bbdl/interest_rates';
my $mocked_file = Test::MockModule->new('Bloomberg::FileDownloader');

my $updater = BOM::MarketDataAutoUpdater::InterestRates->new;
$mocked_file->mock('grab_files' => sub { return "$data_dir/error_check.csv" });

lives_ok { $updater->run } 'run lives_ok';
my $report = $updater->report;
like($report->{error}->[0], qr/error code/, 'skipped if input error');

$mocked_file->mock('grab_files' => sub { return "$data_dir/notnumber.csv" });

$updater = BOM::MarketDataAutoUpdater::InterestRates->new;

$updater->run;
$report = $updater->report;
like($report->{error}->[0], qr/rates\[NotNumber\]/, 'skipped if not number');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/USD AUD JPY/);
$updater = BOM::MarketDataAutoUpdater::InterestRates->new;
$mocked_file->mock('grab_files' => sub { return "$data_dir/data.csv" });

lives_ok { $updater->run } 'run lives_ok';
$report = $updater->report;
ok($report->{'USD'}->{success}, 'USD updated successfully');

$updater = BOM::MarketDataAutoUpdater::InterestRates->new;
$mocked_file->mock('grab_files' => sub { return "$data_dir/complete_data.csv" });

lives_ok { $updater->run } 'run lives_ok';
$report = $updater->report;
ok($report->{'AUD'}->{success}, 'AUD updated successfully');

restore_time();
done_testing;
