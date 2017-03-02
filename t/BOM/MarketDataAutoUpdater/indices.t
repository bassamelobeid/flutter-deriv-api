#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
use Test::Exception;

use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

use Date::Utility;
use File::Temp;
use File::Basename qw(dirname);
use BOM::MarketDataAutoUpdater::Indices;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use LandingCompany::Offerings qw(reinitialise_offerings);

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);


BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'ZAR',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'TOP40',
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

subtest 'more than 4 hours old' => sub {
    my $test_file = dirname(__FILE__) . '/combined_without_DJI.xls';
    my $au        = BOM::MarketDataAutoUpdater::Indices->new(
        file              => $test_file,
        symbols_to_update => [qw(TOP40)]);
    $au->run;
    is keys %{$au->report}, 1, 'only atttempt one underlying if specified';
    ok $au->report->{TOP40}, 'attempts TOP40';
    ok !$au->report->{TOP40}->{success}, 'update failed';
    like $au->report->{TOP40}->{reason}, qr/more than 4 hours old/, 'correct error message';
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
    like $au->report->{TOP40}->{reason}, qr/has not changed since last update/, 'correct error message';
};

SKIP: {
    skip 'Success test does not work on the weekends.', 1 if Date::Utility->today->is_a_weekend;
    subtest 'updated hurray!' => sub {
        my $tmp = File::Temp->newdir;
        # get the real deal because we check date
        `wget -O $tmp/auto_upload.xls 'https://www.dropbox.com/s/yjl5jqe6f71stf5/auto_upload.xls?dl=1' > /dev/null 2>&1`;
        my $au = BOM::MarketDataAutoUpdater::Indices->new(
            file              => "$tmp/auto_upload.xls",
            symbols_to_update => [qw(TOP40)],
        );
        $au->run;
        ok $au->report->{TOP40}->{success}, 'update successful';
    };
}

1;
