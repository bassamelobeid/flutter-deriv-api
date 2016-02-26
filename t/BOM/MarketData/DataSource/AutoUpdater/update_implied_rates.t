#!/usr/bin/perl

use strict;
use warnings;

use Test::More (tests => 4);
use Test::Exception;
use Test::NoWarnings;
use File::Basename qw(dirname);
use Test::MockObject::Extends;

use BOM::Test::Data::Utility::UnitTestMD qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestDatabase;

use Format::Util::Numbers qw(roundnear);
use BOM::MarketData::AutoUpdater::ImpliedInterestRates;

my $data_dir = dirname(__FILE__) . '/../../../../data/bbdl/implied_interest_rates';

subtest 'invalid input' => sub {
    lives_ok {
        my $updater = BOM::MarketData::AutoUpdater::ImpliedInterestRates->new;
        $updater = Test::MockObject::Extends->new($updater);
        $updater->mock('file', sub { $data_dir . '/forward_rates_error.csv' });
        $updater->run;
        my $report = $updater->report;
        like($report->{error}->[0], qr/has error code\[1\]/, 'skipped if input error');

        $updater = BOM::MarketData::AutoUpdater::ImpliedInterestRates->new;
        $updater = Test::MockObject::Extends->new($updater);
        $updater->mock('file', sub { $data_dir . '/forward_rates_notnumber.csv' });
        $updater->run;
        $report = $updater->report;
        like($report->{error}->[0], qr/implied interest rates\[91\.\*\*\*  \]/, 'skipped if not number');
    }
    'error from bloomberg input';
};

subtest 'successful run' => sub {
    lives_ok {
        BOM::Test::Data::Utility::UnitTestMD::create_doc(
            'currency',
            {
                symbol => $_,
                date   => Date::Utility->new,
            }) for (qw/USD AUD JPY/);
        my $updater = BOM::MarketData::AutoUpdater::ImpliedInterestRates->new;
        $updater = Test::MockObject::Extends->new($updater);
        $updater->mock('file', sub { $data_dir . '/data.csv' });
        $updater->run;
        my $report = $updater->report;
        ok($report->{'AUD-JPY'}->{success}, 'AUD-JPY updated successfully');
    }
    'valid data';
};

subtest "sanity check" => sub {
    plan tests => 2;

    BOM::Test::Data::Utility::UnitTestMD::create_doc(
        'currency',
        {
            symbol => 'AUD',
            rates  => {
                1   => 0.1695,
                2   => 0.275,
                7   => 0.1961,
                32  => 0.2457,
                62  => 0.3428,
                92  => 0.4606,
                186 => 2.5,
                365 => 2.6,
            },
            date => Date::Utility->new,
        });

    BOM::Test::Data::Utility::UnitTestMD::create_doc(
        'currency',
        {
            symbol => 'JPY',
            rates  => {
                1   => 0.1173,
                2   => 0.1173,
                7   => 0.1219,
                32  => 0.1437,
                62  => 0.1618,
                92  => 0.1984,
                186 => 0.3355,
                365 => 0.3313,
            },
            date => Date::Utility->new,
        });

    BOM::Test::Data::Utility::UnitTestMD::create_doc(
        'currency',
        {
            symbol => 'USD',
            date   => Date::Utility->new,
        });

    my $updater = BOM::MarketData::AutoUpdater::ImpliedInterestRates->new;
    $updater = Test::MockObject::Extends->new($updater);
    $updater->mock('file', sub { $data_dir . '/sanity.csv' });
    $updater->run;
    ok !$updater->report->{'AUD-JPY'}->{success}, 'not successful';
    like($updater->report->{'AUD-JPY'}->{reason}, qr/not within our acceptable range/, 'mark as fail if implied rates is not within -3% and 15%');
};
