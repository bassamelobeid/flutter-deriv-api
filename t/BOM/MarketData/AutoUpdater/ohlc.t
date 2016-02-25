use Test::Most;
use Test::FailWarnings;
use File::Spec::Functions qw(rel2abs splitpath);
use File::Temp qw(tempdir);

use BOM::MarketData::AutoUpdater::OHLC;
use Test::MockObject::Extends;
use BOM::Utility::Log4perl;
use Test::Log4perl;
use Test::MockModule;

my $abspath   = rel2abs((splitpath(__FILE__))[1]);
my $data_path = $abspath . '/../../../data/bbdl/ohlc';
my $module    = Test::MockModule->new('BOM::Market::Underlying');
$module->mock('has_holiday_on', sub { 0 });

subtest everything => sub {

    my $updater = BOM::MarketData::AutoUpdater::OHLC->new(
        is_a_weekend => 0,
        file         => [],
    );
    lives_ok {
        $updater->run();
        like($updater->report->{error}->[0], qr/File does not exist/, 'returns correct message if file does not exist');
    }
    'file does not exist';

    $updater = BOM::MarketData::AutoUpdater::OHLC->new(
        is_a_weekend => 0,
        file         => [(1 .. 10000)],
    );
    lives_ok {
        $updater->run();
        like($updater->report->{error}->[0], qr/files in Bloomberg seems too big/, 'returns correct message if file is too big');
    }
    'file is too big';

    $updater = BOM::MarketData::AutoUpdater::OHLC->new(
        is_a_weekend => 0,
        file         => ["$data_path/empty.csv"],
    );
    lives_ok {
        $updater->run();
        like($updater->report->{error}->[0], qr/empty/, 'added file name to empty list for empty ohlc file');
    }
    'file is empty';

    $updater = BOM::MarketData::AutoUpdater::OHLC->new(
        is_a_weekend => 0,
        file         => [$data_path . '/invalid_symbol.csv'],
    );
    lives_ok {
        $updater->run();
        like($updater->report->{error}->[0], qr/unregconized bloomberg symbol/i, 'added invalid Bloomberg symbol to skipped list');
        ok !$updater->report->{N225}->{success}, 'N225 failed to update because of invalid date';
        like($updater->report->{N225}->{reason}, qr/Incorrect date/, 'added incorrect date symbol to skipped list');
    }

};

subtest 'valid index' => sub {
    my $updater = BOM::MarketData::AutoUpdater::OHLC->new(
        is_a_weekend      => 0,
        file              => [$data_path . '/valid.csv'],
        directory_to_save => tempdir,
    );
    $updater = Test::MockObject::Extends->new($updater);
    $updater->mock('_passes_sanity_check', sub { '' });
    lives_ok {
        $updater->run();
        ok($updater->report->{HSI}->{success}, 'HSI is updated');
    }
    'ohlc for HSI updated successfully';

};

subtest 'valid stocks' => sub {
    my $updater = BOM::MarketData::AutoUpdater::OHLC->new(
        is_a_weekend      => 0,
        file              => [$data_path . '/stocks.csv'],
        directory_to_save => tempdir,
    );
    $updater = Test::MockObject::Extends->new($updater);
    $updater->mock('_passes_sanity_check', sub { '' });
    lives_ok {
        $updater->run();
        ok($updater->report->{FPFP}->{success}, 'FPFP is updated');
    }
    'ohlc for FPFP updated successfully';
};

subtest 'valid close' => sub {
    my $updater = BOM::MarketData::AutoUpdater::OHLC->new(
        is_a_weekend      => 0,
        file              => [$data_path . '/close.csv'],
        directory_to_save => tempdir,
    );
    $updater = Test::MockObject::Extends->new($updater);
    $updater->mock('_passes_sanity_check', sub { '' });
    lives_ok {
        $updater->run();
        ok!$updater->report->{HSI}->{success}, 'HSI failed to be updated due to close >=5%';
	like($updater->report->{reason}->[0],qr/OHLC big difference/i, 'sanity check for close');
    }
    'close for HSI updated successfully';
};

done_testing
