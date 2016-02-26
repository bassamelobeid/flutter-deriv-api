#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::Exception;
use Test::NoWarnings;

use BOM::Test::Data::Utility::UnitTestMD qw( :init );

use Date::Utility;
use File::Temp;
use File::Basename qw(dirname);
use BOM::MarketData::AutoUpdater::Indices;

BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'currency',
    {
        symbol => 'ZAR',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'index',
    {
        symbol => 'TOP40',
        date   => Date::Utility->new,
    });
my $test_surface = BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'TOP40',
        recorded_date => Date::Utility->new,
    });

subtest 'more than 2 hours old' => sub {
    my $test_file = dirname(__FILE__) . '/combined_without_DJI.xls';
    my $au        = BOM::MarketData::AutoUpdater::Indices->new(
        file              => $test_file,
        symbols_to_update => [qw(TOP40)]);
    $au->run;
    is keys %{$au->report}, 1, 'only atttempt one underlying if specified';
    ok $au->report->{TOP40}, 'attempts TOP40';
    ok !$au->report->{TOP40}->{success}, 'update failed';
    like $au->report->{TOP40}->{reason}, qr/more than 2 hours old/, 'correct error message';
};

subtest 'surface data not found' => sub {
    my $test_file = dirname(__FILE__) . '/combined_without_DJI.xls';
    my $au        = BOM::MarketData::AutoUpdater::Indices->new(
        file              => $test_file,
        symbols_to_update => [qw(CRAPPY)]);    # wrong symbol
    $au->run;
    ok !$au->report->{CRAPPY}->{success}, 'update failed';
    like $au->report->{CRAPPY}->{reason}, qr/missing from datasource/, 'correct error message';
};

subtest 'surface has not change' => sub {
    my $test_file        = dirname(__FILE__) . '/combined_without_DJI.xls';
    my $existing_surface = BOM::Test::Data::Utility::UnitTestMD::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'TOP40',
            recorded_date => Date::Utility->new(Date::Utility->new - 18000),
        });
    my $au = BOM::MarketData::AutoUpdater::Indices->new(
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
        `wget -O $tmp/auto_upload.xls 'https://www.dropbox.com/s/67s60tryh057qx1/auto_upload.xls?dl=1' > /dev/null 2>&1`;
        my $au = BOM::MarketData::AutoUpdater::Indices->new(
            file              => "$tmp/auto_upload.xls",
            symbols_to_update => [qw(TOP40)],
        );
        $au->run;
        ok $au->report->{TOP40}->{success}, 'update successful';
    };
}

1;
