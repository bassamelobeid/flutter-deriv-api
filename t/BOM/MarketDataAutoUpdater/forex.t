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
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use Postgres::FeedDB::Spot;
use LandingCompany::Offerings qw(reinitialise_offerings);
use Quant::Framework::VolSurface::Utils qw(NY1700_rollover_date_on);

$ENV{QUANT_FRAMEWORK_HOLIDAY_CACHE} = 0;
use Postgres::FeedDB::Spot;
my $module = Test::MockModule->new('Postgres::FeedDB::Spot');
$module->mock(
    'spot_tick',
    sub {
        my $self = shift;
        return Postgres::FeedDB::Spot::Tick->new({
            epoch => time,
            quote => 100,
        });
    });

use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::MarketDataAutoUpdater::Forex;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

# Prep:
my $fake_date = Date::Utility->new('2012-08-13 15:55:55');
set_absolute_time($fake_date->epoch);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/JPY USD GBP INR AUD/);

create_underlying({symbol => 'frxGBPINR'})->set_combined_realtime({
    epoch => $fake_date->epoch,
    quote => 100,
});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'holiday',
    {
        recorded_date => $fake_date,
        calendar      => {
            '2013-01-01' => {
                'New Year' => ['FOREX'],
            }
        },
    });
Quant::Framework::Utils::Test::create_doc(
    'volsurface_delta',
    {
        underlying       => create_underlying($_),
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
        recorded_date    => Date::Utility->new,
    }) for qw(frxAUDJPY frxGBPJPY frxUSDJPY frxGBPINR);

initialize_realtime_ticks_db;

subtest 'Basics.' => sub {
    my $auf = BOM::MarketDataAutoUpdater::Forex->new(file => ['t/data/bbdl/vol_points/2012-08-13/fx000000.csv']);
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

my $usdjpy = create_underlying('frxUSDJPY');

my $fake_surface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        underlying    => $usdjpy,
        surface       => $data,
        recorded_date => Date::Utility->new(time - (4 * 3600 + 1)),
    });

subtest 'more than 4 hours old' => sub {
    my $au = BOM::MarketDataAutoUpdater::Forex->new(
        symbols_to_update  => ['frxUSDJPY'],
        _connect_ftp       => 0,
        surfaces_from_file => {frxUSDJPY => $fake_surface});
    lives_ok { $au->run } 'run without dying';
    is keys %{$au->report}, 1, 'only process one underlying';
    ok $au->report->{frxUSDJPY}, 'process frxUSDJPY';
    ok !$au->report->{frxUSDJPY}->{success}, 'update failed';
    like $au->report->{frxUSDJPY}->{reason}, qr/is expired/, 'reason: more than 4 hours old';
};

subtest 'does not exists' => sub {
    my $au = BOM::MarketDataAutoUpdater::Forex->new(
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

$fake_surface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        underlying    => $usdjpy,
        recorded_date => Date::Utility->new(time - 7199),
        surface       => $data
    });

subtest 'big jump' => sub {
    my $au = BOM::MarketDataAutoUpdater::Forex->new(
        symbols_to_update  => ['frxUSDJPY'],
        _connect_ftp       => 0,
        surfaces_from_file => {frxUSDJPY => $fake_surface});
    lives_ok { $au->run } 'run without dying';
    ok !$au->report->{frxUSDJPY}->{success}, 'update failed';
    like $au->report->{frxUSDJPY}->{reason}, qr/big jump/, 'reason: big jump';
};

my $clone = dclone($data);
$clone->{14}->{smile}->{25} = 1.3;

$fake_surface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        underlying    => $usdjpy,
        recorded_date => Date::Utility->new(time - 7199),
        surface       => $clone,
        save          => 0,
    });

subtest 'big difference' => sub {
    my $au = BOM::MarketDataAutoUpdater::Forex->new(
        symbols_to_update  => ['frxUSDJPY'],
        _connect_ftp       => 0,
        surfaces_from_file => {
            frxUSDJPY => {
                surface       => $fake_surface->surface_data,
                recorded_date => $fake_surface->recorded_date,
                type          => $fake_surface->type
            }});
    lives_ok { $au->run } 'run without dying';
    ok !$au->report->{frxUSDJPY}->{success}, 'update failed';
    like $au->report->{frxUSDJPY}->{reason}, qr/big jump/, 'reason: big jump';
};

$fake_surface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        underlying    => $usdjpy,
        recorded_date => Date::Utility->new(time - 7199),
    });

subtest 'save valid' => sub {
    my $au = BOM::MarketDataAutoUpdater::Forex->new(
        symbols_to_update  => ['frxUSDJPY'],
        _connect_ftp       => 0,
        surfaces_from_file => {
            frxUSDJPY => {
                surface       => $fake_surface->surface_data,
                recorded_date => $fake_surface->recorded_date,
                type          => $fake_surface->type
            }});
    lives_ok { $au->run } 'run without dying';
    ok $au->report->{frxUSDJPY}->{success}, 'update successful';
};

subtest "Friday after close, weekend, won't open check." => sub {
    plan tests => 8;

    my $auf = BOM::MarketDataAutoUpdater::Forex->new;

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
        my $surface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'volsurface_delta',
            {
                underlying    => $usdjpy,
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

subtest 'do not update one hour after rollover' => sub {
    my $rollover_date = NY1700_rollover_date_on($fake_date);

    my $au = BOM::MarketDataAutoUpdater::Forex->new(
        symbols_to_update  => ['frxUSDJPY'],
        _connect_ftp       => 0,
        surfaces_from_file => {
            frxUSDJPY => {
                surface       => $fake_surface->surface_data,
                recorded_date => $rollover_date,
                type          => $fake_surface->type
            }});
    lives_ok { $au->run } 'run without dying';
    ok !$au->report->{frxUSDJPY}, 'update skipped';
    $au = BOM::MarketDataAutoUpdater::Forex->new(
        symbols_to_update  => ['frxUSDJPY'],
        _connect_ftp       => 0,
        surfaces_from_file => {
            frxUSDJPY => {
                surface       => $fake_surface->surface_data,
                recorded_date => $rollover_date->plus_time_interval('1h1s'),
                type          => $fake_surface->type
            }});
    lives_ok { $au->run } 'run without dying';
    ok $au->report->{frxUSDJPY}->{success}, 'update successful';
};

restore_time();
