use Test::Most;
use File::Basename qw(dirname);
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

use BOM::MarketDataAutoUpdater::InterestRates;

my $data_dir    = dirname(__FILE__) . '/../../data/bbdl/interest_rates';
my $mocked_file = Test::MockModule->new('Bloomberg::FileDownloader');

my $updater = BOM::MarketDataAutoUpdater::InterestRates->new;
$mocked_file->mock('grab_files' => sub { return "$data_dir/forward_rates_error.csv" });

lives_ok { $updater->run } 'run lives_ok';
my $report = $updater->report;
like($report->{error}->[0], qr/error code/, 'skipped if input error');

$mocked_file->mock('grab_files' => sub { return "$data_dir/forward_rates_notnumber.csv" });

$updater = BOM::MarketDataAutoUpdater::InterestRates->new;

$updater->run;
$report = $updater->report;
like($report->{error}->[0], qr/rates\[91\.\*\*\*  \]/, 'skipped if not number');

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

done_testing;
