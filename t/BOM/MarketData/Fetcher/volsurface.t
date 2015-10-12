use Test::Most;
use Test::FailWarnings;
use Test::MockTime qw( set_absolute_time restore_time );
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Runtime qw(:normal);
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Market::Underlying;
use BOM::MarketData::VolSurface::Delta;
use BOM::MarketData::VolSurface::Moneyness;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::MarketData::VolSurface::Cutoff;

initialize_realtime_ticks_db();

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'EUR',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'FOREX',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'FSE',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'RANDOM',
        date   => Date::Utility->new,
    });

my $dm = BOM::MarketData::Fetcher::VolSurface->new;

subtest 'Saving delta then moneyness.' => sub {
    plan tests => 2;

    my $forex = BOM::Market::Underlying->new('frxUSDJPY');

    my $delta_surface = BOM::MarketData::VolSurface::Delta->new({
            deltas        => [75, 50, 25],
            underlying    => $forex,
            recorded_date => Date::Utility->new,
            surface       => {
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
        cutoff     => 'New York 10:00'
    });

    is_deeply($saved->surface, $delta_surface->surface, 'Delta surface matches.');

    my $indices           = BOM::Market::Underlying->new('GDAXI');
    my $moneyness_surface = BOM::MarketData::VolSurface::Moneyness->new({
            moneynesses   => [99, 100, 101],
            underlying    => $indices,
            recorded_date => Date::Utility->new,
            surface       => {
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

subtest 'Fetch cut.' => sub {
    plan tests => 4;

    my $original = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxUSDJPY',
            recorded_date => Date::Utility->new,
        });

    my $cut_surface = $dm->fetch_surface({
        underlying => BOM::Market::Underlying->new('frxUSDJPY'),
        cutoff     => 'UTC 10:24',
    });
    is($cut_surface->cutoff->code, 'UTC 10:24', 'Fetched cut surface has intended cutoff.');

    cmp_ok(
        $cut_surface->get_volatility({
                delta => 25,
                days  => 7
            }
        ),
        '!=',
        $original->get_volatility({
                delta => 25,
                days  => 7
            }
        ),
        'Cut surface has different vol from original.'
    );

    $cut_surface = $dm->fetch_surface({
        underlying => BOM::Market::Underlying->new('frxUSDJPY'),
        cutoff     => BOM::MarketData::VolSurface::Cutoff->new('UTC 10:25'),
    });
    is($cut_surface->cutoff->code, 'UTC 10:25', 'Passing a Cutoff object to fetch_surface.');

    $cut_surface = $dm->fetch_surface({
        underlying => BOM::Market::Underlying->new('frxUSDJPY'),
        cutoff     => 'UTC 10:25',
    });
    is($cut_surface->cutoff->code, 'UTC 10:25', 'Fetching a cut surface that has already been cut.');
};

subtest 'recorded_date on Randoms.' => sub {
    plan tests => 2;

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_flat',
        {
            symbol        => 'R_100',
            recorded_date => Date::Utility->new,
        });

    my $for_date = Date::Utility->new('2012-08-01 10:00:00');
    my $surface  = $dm->fetch_surface({
        underlying => BOM::Market::Underlying->new('R_100'),
        for_date   => $for_date
    });
    is($surface->recorded_date->datetime, $for_date->datetime, 'fetch_surface on a Random Index surface with given for_date.');

    my $now = Date::Utility->new('2012-08-01 10:00:00');
    set_absolute_time($now->epoch);
    $surface = $dm->fetch_surface({underlying => BOM::Market::Underlying->new('R_100')});
    is($surface->recorded_date->datetime, $now->datetime, 'fetch_surface on a Random Index surface "now".');
    restore_time();
};

subtest 'Consecutive saves.' => sub {
    plan tests => 8;

    my $underlying = BOM::Market::Underlying->new('frxEURUSD');

    my $surface = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_delta',
        {
            recorded_date => Date::Utility->new(time - 3 * 3600),
            underlying    => $underlying,
        });
    my @recorded_dates = ($surface->recorded_date);    # keep track of all saved surface recorded_dates

    is(scalar keys %{$surface->document->{surfaces}}, 3, 'saves the cut surface');

    for (0 .. 2) {
        my $recorded_date = Date::Utility->new(time - (2 - $_) * 3600);
        BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
            'volsurface_delta',
            {
                recorded_date => $recorded_date,
                underlying    => $underlying,
            });
        unshift @recorded_dates, $recorded_date;
    }

    my $datasources = BOM::Platform::Runtime->instance->datasources;
    my $client      = CouchDB::Client->new(uri => $datasources->couchdb->replica->uri);
    my $db          = $client->newDB($datasources->couchdb_databases->{volatility_surfaces});
    my $doc         = $db->newDoc($underlying->symbol);

    throws_ok { $doc->fetchAttachment('historical') } qr/No such attachment/, '"Current" doc does not have attachment.';

    my $dm = BOM::MarketData::Fetcher::VolSurface->new;
    my $current = $dm->fetch_surface({underlying => $underlying});
    is($current->recorded_date->datetime, $recorded_dates[0]->datetime, 'Current surface has expected date.');

    my $first_historical = $dm->fetch_surface({
        underlying => $underlying,
        for_date   => Date::Utility->new($current->recorded_date->epoch - 1),
    });
    is($first_historical->recorded_date->datetime, $recorded_dates[1]->datetime, 'First historical surface has expected date.');

    $first_historical = $dm->fetch_surface({
        underlying => $underlying,
        for_date   => $first_historical->recorded_date,
    });
    is($first_historical->recorded_date->datetime, $recorded_dates[1]->datetime, 'First historical surface fetch correctly when its own date given.');

    my $second_historical = $dm->fetch_surface({
        underlying => $underlying,
        for_date   => Date::Utility->new($first_historical->recorded_date->epoch - 1),
    });
    is($second_historical->recorded_date->datetime, $recorded_dates[2]->datetime, 'Second historical surface has expected date.');

    is(scalar keys %{$surface->document->{surfaces}}, 3, 'Cuts remain after surface has been saved to history.');

    # Ensure we cannot save an historical surface.
    throws_ok { $second_historical->save } qr/Saving historical document not permitted/, 'Cannot save historical surface.';
};

done_testing;
