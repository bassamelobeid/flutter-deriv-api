use strict;
use warnings;

use Storable qw(dclone);
use Test::MockObject::Extends;
use Test::Exception;
use File::Basename qw( dirname );
use File::Temp;
use Test::Deep qw( cmp_deeply );
use Test::MockTime qw( restore_time set_absolute_time );
use Test::More qw( no_plan );
use Test::NoWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestMD qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::MarketData::AutoUpdater::Forex;
initialize_realtime_ticks_db;

# Prep:
my $fake_date = Date::Utility->new('2012-08-13 15:55:55');
set_absolute_time($fake_date->epoch);

BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/JPY USD GBP INR AUD/);

BOM::Market::Underlying->new({symbol => 'frxGBPINR'})->set_combined_realtime({
    epoch => $fake_date->epoch,
    quote => 100,
});

BOM::Test::Data::Utility::UnitTestMD::create_doc('holiday', {
    recorded_date => $fake_date,
    calendar => {
        '2013-01-01' => {
            'New Year' => ['FOREX'],
        }
    },
    });
BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new,
    }) for qw(frxAUDJPY frxGBPJPY frxUSDJPY frxGBPINR);

subtest 'Basics.' => sub {
    my $auf     = BOM::MarketData::AutoUpdater::Forex->new;
    my @symbols = @{$auf->symbols_to_update};
    ok(scalar(@symbols), 'symbols_to_update is non-empty by default.');
    cmp_ok(scalar(@symbols), '==', (grep { /^frx/ } @symbols), 'All symbols_to_udpate are FX.');
};

my $data = {
    7 => {
        smile => {
            25 => 0.12 + rand(0.01),
            50 => 0.12,
            75 => 0.11
        },
        vol_spread => {50 => 0.1}
    },
    14 => {
        smile => {
            25 => 0.12,
            50 => 0.12,
            75 => 0.11
        },
        vol_spread => {50 => 0.1}
    },
};
my $fake_surface = BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        surface       => $data,
        recorded_date => Date::Utility->new(time - 7210),
    });

subtest 'more than 2 hours old' => sub {
    my $au = BOM::MarketData::AutoUpdater::Forex->new(
        symbols_to_update  => ['frxUSDJPY'],
        _connect_ftp       => 0,
        surfaces_from_file => {frxUSDJPY => $fake_surface});
    lives_ok { $au->run } 'run without dying';
    is keys %{$au->report}, 1, 'only process one underlying';
    ok $au->report->{frxUSDJPY}, 'process frxUSDJPY';
    ok !$au->report->{frxUSDJPY}->{success}, 'update failed';
    like $au->report->{frxUSDJPY}->{reason}, qr/more than 2 hours/, 'reason: more than 2 hours old';
};

subtest 'does not exists' => sub {
    my $au = BOM::MarketData::AutoUpdater::Forex->new(
        symbols_to_update  => ['frxUSDJPY'],
        _connect_ftp       => 0,
        surfaces_from_file => {frxGBPJPY => $fake_surface});
    lives_ok { $au->run } 'run without dying';
    ok !$au->report->{frxUSDJPY}->{success}, 'update failed';
    like $au->report->{frxUSDJPY}->{reason}, qr/missing from datasource/, 'reason: missing from datasource';
};

$data = {
    7 => {
        smile => {
            25 => 0.1,
            50 => 0.12,
            75 => 0.11
        },
        vol_spread => {50 => 0.1}
    },
    14 => {
        smile => {
            25 => 0.42,
            50 => 0.12,
            75 => 0.11
        },
        vol_spread => {50 => 0.1}
    },
};

$fake_surface = BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => Date::Utility->new(time - 7199),
        surface       => $data
    });

subtest 'big jump' => sub {
    my $au = BOM::MarketData::AutoUpdater::Forex->new(
        symbols_to_update  => ['frxUSDJPY'],
        _connect_ftp       => 0,
        surfaces_from_file => {frxUSDJPY => $fake_surface});
    lives_ok { $au->run } 'run without dying';
    ok !$au->report->{frxUSDJPY}->{success}, 'update failed';
    like $au->report->{frxUSDJPY}->{reason}, qr/big jump/, 'reason: big jump';
};

my $clone = dclone($data);
$clone->{14}->{smile}->{25} = 1.3;

$fake_surface = BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => Date::Utility->new(time - 7199),
        surface       => $clone,
        save          => 0,
    });

subtest 'big difference' => sub {
    my $au = BOM::MarketData::AutoUpdater::Forex->new(
        symbols_to_update  => ['frxUSDJPY'],
        _connect_ftp       => 0,
        surfaces_from_file => {frxUSDJPY => $fake_surface});
    lives_ok { $au->run } 'run without dying';
    ok !$au->report->{frxUSDJPY}->{success}, 'update failed';
    like $au->report->{frxUSDJPY}->{reason}, qr/big jump/, 'reason: big jump';
};

$fake_surface = BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => Date::Utility->new(time - 7199),
        save          => 0,
    });

subtest 'save valid' => sub {
    my $au = BOM::MarketData::AutoUpdater::Forex->new(
        symbols_to_update  => ['frxUSDJPY'],
        _connect_ftp       => 0,
        surfaces_from_file => {frxUSDJPY => $fake_surface});
    lives_ok { $au->run } 'run without dying';
    ok $au->report->{frxUSDJPY}->{success}, 'update successful';
};

subtest "Friday after close, weekend, won't open check." => sub {
    plan tests => 8;

    my $auf = BOM::MarketData::AutoUpdater::Forex->new;

    my %test_data = (
        wont_open => {
            datetime => '2013-01-01 06:06:06',
            success  => 0,
        },
        friday_before_close => {
            datetime => '2013-02-01 20:59:59',
            success  => 1,
        },
        friday_after_close => {
            datetime => '2013-02-01 21:00:01',
            success  => 0,
        },
        weekend => {
            datetime => '2013-02-02 12:34:56',
            success  => 0,
        },
        effective_monday_morning => {
            datetime => '2013-02-03 23:00:00',
            success  => 1,
        },
    );

    while (my ($name, $details) = each %test_data) {
        my $surface = BOM::Test::Data::Utility::UnitTestMD::create_doc(
            'volsurface_delta',
            {
                recorded_date => Date::Utility->new($details->{datetime}),
            });

        my $result = $auf->passes_additional_check($surface);
        cmp_ok($result, '==', $details->{success}, "Surface with recorded_date for the '$name' test doesn't update.");

        if (not $result) {
            is(
                $surface->validation_error,
                'Not updating surface as it is the weekend or the underlying will not open.',
                '...as indicated by the reason.'
            );
        }
    }
};

restore_time();
