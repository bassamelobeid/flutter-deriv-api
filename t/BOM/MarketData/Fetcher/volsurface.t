use Test::Most;
use Test::FailWarnings;
use Test::MockTime qw( set_absolute_time restore_time );
use Test::MockModule;
use File::Spec;

use Date::Utility;
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::MarketData::Fetcher::VolSurface;
use Quant::Framework::VolSurface::Delta;
use Quant::Framework::VolSurface::Moneyness;
use Quant::Framework::Utils::Test;

initialize_realtime_ticks_db();
my $now = Date::Utility->new;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'EUR',
        date   => $now,
    });
my $dm = BOM::MarketData::Fetcher::VolSurface->new;

subtest 'Saving delta then moneyness.' => sub {
    plan tests => 2;

    my $forex = create_underlying('frxUSDJPY');

    my $delta_surface = Quant::Framework::VolSurface::Delta->new({
            deltas           => [75, 50, 25],
            underlying       => $forex,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
            creation_date    => $now,
            surface          => {
                1 => {
                    smile => {
                        25 => 0.19,
                        50 => 0.15,
                        75 => 0.23,
                    },
                    vol_spread => {
                        50 => 0.02,
                    },
                },
            },
        });
    $delta_surface->save;

    my $saved = $dm->fetch_surface({
        underlying => $forex,
    });

    is_deeply($saved->surface, $delta_surface->surface, 'Delta surface matches.');

    my $indices           = create_underlying('GDAXI');
    my $moneyness_surface = Quant::Framework::VolSurface::Moneyness->new({
            moneynesses      => [99, 100, 101],
            underlying       => $indices,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
            creation_date    => $now,
            surface          => {
                7 => {
                    smile => {
                        99  => 0.3,
                        100 => 0.2,
                        101 => 0.1,
                    },
                    vol_spread => {
                        50 => 0.05,

                    },
                },
            },
            spot_reference => 100,
        });

    $moneyness_surface->save;

    $saved = $dm->fetch_surface({underlying => $indices});
    is_deeply($saved->surface, $moneyness_surface->surface, 'Moneyness surface matches.');
};

subtest 'creation_date on Randoms.' => sub {
    plan tests => 2;

    my $now = Date::Utility->new('2012-08-01 10:00:00');
    set_absolute_time($now->epoch);
    my $surface = $dm->fetch_surface({
        underlying => create_underlying('R_100'),
        for_date   => $now->minus_time_interval('1d'),
    });
    note('Recorded date should be at most 2 seconds from ' . $now->datetime);
    cmp_ok($surface->creation_date->epoch - $now->epoch, '<=', 2, 'fetch_surface on a Random Index surface with given for_date.');

    $surface = $dm->fetch_surface({underlying => create_underlying('R_100')});
    is($surface->creation_date->datetime, $now->datetime, 'fetch_surface on a Random Index surface "now".');
    restore_time();
};

subtest 'Consecutive saves.' => sub {
    plan tests => 4;

    my $underlying = create_underlying('frxEURUSD');

    my $surface = Quant::Framework::Utils::Test::create_doc(
        'volsurface_delta',
        {
            recorded_date    => $now->minus_time_interval('3h'),
            underlying       => $underlying,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
        });
    my @creation_dates = ($surface->creation_date);    # keep track of all saved surface creation_dates

    for (0 .. 2) {
        my $recorded_date = $now->minus_time_interval(2 - $_ . 'h');
        Quant::Framework::Utils::Test::create_doc(
            'volsurface_delta',
            {
                recorded_date    => $recorded_date,
                underlying       => $underlying,
                chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
                chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
            });
        unshift @creation_dates, $recorded_date;
    }

    my $dm      = BOM::MarketData::Fetcher::VolSurface->new;
    my $current = $dm->fetch_surface({underlying => $underlying});
    is($current->creation_date->datetime, $creation_dates[0]->datetime, 'Current surface has expected date.');

    my $first_historical = $dm->fetch_surface({
        underlying => $underlying,
        for_date   => Date::Utility->new($current->creation_date->epoch - 1),
    });
    is($first_historical->creation_date->datetime, $creation_dates[1]->datetime, 'First historical surface has expected date.');

    $first_historical = $dm->fetch_surface({
        underlying => $underlying,
        for_date   => $first_historical->creation_date,
    });
    is($first_historical->creation_date->datetime, $creation_dates[1]->datetime, 'First historical surface fetch correctly when its own date given.');

    my $second_historical = $dm->fetch_surface({
        underlying => $underlying,
        for_date   => Date::Utility->new($first_historical->creation_date->epoch - 1),
    });
    is($second_historical->creation_date->datetime, $creation_dates[2]->datetime, 'Second historical surface has expected date.');
};

done_testing;
