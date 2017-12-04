use Test::MockTime qw( restore_time set_absolute_time );
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Test::Most;
use Test::FailWarnings;
use File::Spec::Functions qw(rel2abs splitpath);
use File::Temp qw(tempdir);
use Date::Utility;
use BOM::MarketDataAutoUpdater::OHLC;
use Test::MockObject::Extends;
use Test::MockModule;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Chronicle;
use Quant::Framework;

my $abspath   = rel2abs((splitpath(__FILE__))[1]);
my $data_path = $abspath . '/../../data/bbdl/ohlc';
my $module    = Test::MockModule->new('Quant::Framework::Underlying');
$module->mock('has_holiday_on', sub { 0 });
initialize_realtime_ticks_db();
subtest everything => sub {

    my $updater = BOM::MarketDataAutoUpdater::OHLC->new(
        is_a_weekend => 0,
        file         => [],
    );
    lives_ok {
        $updater->run();
        like($updater->report->{error}->[0], qr/File does not exist/, 'returns correct message if file does not exist');
    }
    'file does not exist';

    $updater = BOM::MarketDataAutoUpdater::OHLC->new(
        is_a_weekend => 0,
        file         => [(1 .. 10000)],
    );
    lives_ok {
        $updater->run();
        like($updater->report->{error}->[0], qr/files in Bloomberg seems too big/, 'returns correct message if file is too big');
    }
    'file is too big';

    $updater = BOM::MarketDataAutoUpdater::OHLC->new(
        is_a_weekend => 0,
        file         => ["$data_path/empty.csv"],
    );
    lives_ok {
        $updater->run();
        like($updater->report->{error}->[0], qr/empty/, 'added file name to empty list for empty ohlc file');
    }
    'file is empty';

    $updater = BOM::MarketDataAutoUpdater::OHLC->new(
        is_a_weekend => 0,
        file         => [$data_path . '/invalid_symbol.csv'],
    );
    lives_ok {
        $updater->run();
        like($updater->report->{error}->[0], qr/unregconized bloomberg symbol/i, 'added invalid Bloomberg symbol to skipped list');
        ok !$updater->report->{N225}->{success}, 'N225 failed to update because of invalid date';
        my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader());
        my $underlying = create_underlying('N225');
        SKIP: {
            # OHLC::_passes_sanity_check has no chance to produce correct error if market is closed for now
            skip "No tradings on weekends" unless $trading_calendar->trades_on($underlying->exchange, Date::Utility->new);
            like($updater->report->{N225}->{reason}, qr/Incorrect date/, 'added incorrect date symbol to skipped list');
        }
    }

};
set_absolute_time(Date::Utility->new('2014-01-10 08:00:00')->epoch);

subtest 'valid index' => sub {
    my $updater = BOM::MarketDataAutoUpdater::OHLC->new(
        file              => [$data_path . '/valid.csv'],
        directory_to_save => tempdir,
    );
    lives_ok {
        update_combined_realtime(
            underlying_symbol => 'HSI',
            datetime          => Date::Utility->new,
            tick              => {quote => 10192.45},
        );

        $updater->run();
        ok($updater->report->{HSI}->{success}, 'HSI is updated');
    }
    'ohlc for HSI updated successfully';

};

subtest 'valid stocks' => sub {
    my $updater = BOM::MarketDataAutoUpdater::OHLC->new(
        file              => [$data_path . '/stocks.csv'],
        directory_to_save => tempdir,
    );
    lives_ok {
        update_combined_realtime(
            underlying_symbol => 'FPFP',
            datetime          => Date::Utility->new,
            tick              => {quote => 33},
        );

        $updater->run();
        ok($updater->report->{FPFP}->{success}, 'FPFP is updated');
    }
    'ohlc for FPFP updated successfully';
};

restore_time();
subtest 'valid close' => sub {
    my $updater = BOM::MarketDataAutoUpdater::OHLC->new(
        is_a_weekend      => 0,
        file              => [$data_path . '/close.csv'],
        directory_to_save => tempdir,
    );

    lives_ok {

        set_absolute_time(Date::Utility->new('2016-02-24')->epoch);
        update_combined_realtime(
            underlying_symbol => 'HSI',
            datetime          => Date::Utility->new,
            tick              => {quote => 19192.45},
        );

        $updater->run();
        ok !$updater->report->{HSI}->{success}, 'HSI failed to be updated due to close >=5%';
        like($updater->report->{HSI}->{reason}, qr/OHLC big difference/i, 'sanity check for close');
    }
    'close for HSI updated successfully';
};

# update_combined_realtime(
#   datetime => $bom_date,            # tick time
#   underlying => $model_underlying,  # underlying
#   tick => {                         # tick data
#       open  => $open,
#       quote => $last_price,         # latest price
#       ticks => $numticks,           # number of ticks
#   },
#)
##################################################################################################
sub update_combined_realtime {
    my %args = @_;
    $args{underlying} = create_underlying($args{underlying_symbol});
    my $underlying_symbol = $args{underlying}->symbol;
    my $unixtime          = $args{datetime}->epoch;
    my $marketitem        = $args{underlying}->market->name;
    my $tick              = $args{tick};

    $tick->{epoch} = $unixtime;
    my $res = $args{underlying}->set_combined_realtime($tick);

    if (scalar grep { $args{underlying}->symbol eq $_ } (create_underlying_db->symbols_for_intraday_fx)) {
        BOM::Market::AggTicks->new->add({
            symbol => $args{underlying}->symbol,
            epoch  => $tick->{epoch},
            quote  => $tick->{quote},
        });
    }
    return 1;
}

done_testing
