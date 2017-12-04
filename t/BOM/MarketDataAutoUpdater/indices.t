#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 7;
use Test::Exception;
use Test::MockModule;
use Test::Warnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

use Date::Utility;
use File::Temp;
use File::Basename qw(dirname);
use BOM::MarketDataAutoUpdater::Indices;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Test::MockModule;


# some checks hide failures output if market is no open
# but tests still want it to fail, so let's make markets always open
my $module = Test::MockModule->new('Finance::Calendar');
$module->mock('is_open', sub { return 1; });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'ZAR',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'AUD',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'TOP40',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'AS51',
        date   => Date::Utility->new,
    });

my $test_surface = Quant::Framework::Utils::Test::create_doc(
    'volsurface_moneyness',
    {
        underlying       => create_underlying('TOP40'),
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
        recorded_date    => Date::Utility->new,
    });

my $test_surface2 = Quant::Framework::Utils::Test::create_doc(
    'volsurface_moneyness',
    {
        underlying       => create_underlying('AS51'),
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
        recorded_date    => Date::Utility->new,
    });

subtest 'more than 4 hours old' => sub {
    my $test_file = dirname(__FILE__) . '/combined_without_DJI.xls';
    my $au        = BOM::MarketDataAutoUpdater::Indices->new(
        file              => $test_file,
        symbols_to_update => [qw(TOP40)]);
    $au->run;
    is keys %{$au->report}, 1, 'only atttempt one underlying if specified';
    ok $au->report->{TOP40}, 'attempts TOP40';
    ok !$au->report->{TOP40}->{success}, 'update failed';
    like $au->report->{TOP40}->{reason}, qr/is expired/, 'correct error message';
};

subtest 'surface data not found' => sub {
    my $test_file = dirname(__FILE__) . '/combined_without_DJI.xls';
    my $au        = BOM::MarketDataAutoUpdater::Indices->new(
        file              => $test_file,
        symbols_to_update => [qw(CRAPPY)]);    # wrong symbol
    $au->run;
    ok !$au->report->{CRAPPY}->{success}, 'update failed';
    like $au->report->{CRAPPY}->{reason}, qr/missing from datasource/, 'correct error message';
};

subtest 'surface has not change' => sub {
    my $test_file        = dirname(__FILE__) . '/combined_without_DJI.xls';
    my $existing_surface = Quant::Framework::Utils::Test::create_doc(
        'volsurface_moneyness',
        {
            underlying       => create_underlying('TOP40'),
            chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
            chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
            recorded_date    => Date::Utility->new(Date::Utility->new - 18000),
        });
    my $au = BOM::MarketDataAutoUpdater::Indices->new(
        file               => $test_file,
        symbols_to_update  => [qw(TOP40)],
        surfaces_from_file => {TOP40 => $test_surface});
    $au->run;
    ok !$au->report->{TOP40}->{success}, 'update failed';
    like $au->report->{TOP40}->{reason}, qr/identical to existing one, and existing is expired/, 'correct error message';
};

my $mocked = Test::MockModule->new('Quant::Framework::VolSurface');
$mocked->mock('_validate_age', sub { return });
$mocked->mock('is_valid',      sub { return 1; });
subtest 'First Term is 7' => sub {
    my $test_file        = dirname(__FILE__) . '/auto_upload.xls';
    my $existing_surface = Quant::Framework::Utils::Test::create_doc(
        'volsurface_moneyness',
        {
            underlying       => create_underlying('AS51'),
            chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
            chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
            recorded_date    => Date::Utility->new,
        });
    my $au = BOM::MarketDataAutoUpdater::Indices->new(
        file              => $test_file,
        symbols_to_update => [qw(AS51)]);    # wrong symbol
    $au->run;
    cmp_ok($au->report->{AS51}->{success}, '==', 1);

};

subtest 'First Term is not 7' => sub {
    my $test_file = dirname(__FILE__) . '/auto_upload_wrong.xls';
    my $au        = BOM::MarketDataAutoUpdater::Indices->new(
        file              => $test_file,
        symbols_to_update => [qw(AS51)]);    # wrong symbol
    $au->run;
    ok !$au->report->{AS51}->{success}, 'update failed';
    print "### " . $au->report->{AS51}->{reason} . "\n";
    like $au->report->{AS51}->{reason}, qr/Term 7 is missing from datasource for/, 'correct error message';
};
$mocked->unmock_all();

SKIP: {
    skip 'Success test does not work on the weekends.', 1 if Date::Utility->today->is_a_weekend;
    subtest 'updated hurray!' => sub {
        my $tmp = File::Temp->newdir;
        # get the real deal because we check date
        `wget -O $tmp/auto_upload.xls 'https://www.dropbox.com/s/yjl5jqe6f71stf5/auto_upload.xls?dl=1' > /dev/null 2>&1`;

        my @symbols_to_update = grep { $_ !~ /^OTC_/ } create_underlying_db->get_symbols_for(
            market            => 'indices',
            contract_category => 'ANY',
        );

        my $au = BOM::MarketDataAutoUpdater::Indices->new(
            file              => "$tmp/auto_upload.xls",
            symbols_to_update => \@symbols_to_update
        );
        $au->run;

        my @success = grep { $au->report->{$_}->{success} == 1 } keys %{$au->report};
        cmp_ok(scalar(@success), '>=', 1), 'update success';

    };
}

1;
