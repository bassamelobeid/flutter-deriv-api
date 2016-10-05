use Test::Most;
use utf8;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

use Postgres::FeedDB::Spot::OHLC;
use BOM::Market::Underlying;
use Date::Utility;

my @time_spots = (
    {
        't'    => '02:00:00',
        'spot' => 100.6
    },
    {
        't'    => '05:00:00',
        'spot' => 100.7
    },
    {
        't'    => '09:00:00',
        'spot' => 100.8
    },
    {
        't'    => '11:00:00',
        'spot' => 100.9
    },
    {
        't'    => '12:00:00',
        'spot' => 100.1
    },
    {
        't'    => '14:00:00',
        'spot' => 100.2
    },
    {
        't'    => '17:00:00',
        'spot' => 100.3
    },
    {
        't'    => '21:00:00',
        'spot' => 100.4
    },
    {
        't'    => '23:00:00',
        'spot' => 100.5
    },

);

my @dates = (
    '2013-10-01', '2013-10-04', '2013-10-06', '2013-10-08', '2013-10-10', '2013-10-13', '2013-10-16', '2013-10-20', '2013-10-24', '2013-10-29',
    '2013-10-31', '2013-11-04', '2013-11-07', '2013-11-13', '2013-11-17', '2013-11-22', '2013-11-27', '2013-11-30', '2013-12-04', '2013-12-07',
);

my $symbol     = 'RDBULL';

subtest 'prepare ticks' => sub {
    my @ticks;
    my $count = 0;

    foreach my $date (@dates) {
        foreach my $time_spot (@time_spots) {
            my $time = $time_spot->{t};
            my $spot = $time_spot->{spot} + $count * 10;

            # if daily open = 12GMT, daily ohlc for 2013-12-01:
            # '2013-11-30 12:00:00' <= OHLC < '2013-12-01 12:00:00'
            # Thus to form complete ohlc day, we shift date to 1 day back for some ticks here
            my $bom_date = Date::Utility->new($date . ' ' . $time);

            push @ticks,
                {
                date  => $bom_date->datetime_yyyymmdd_hhmmss,
                quote => $spot,
                bid   => $spot,
                ask   => $spot,
                };
        }
        $count++;
    }

    my $date;
    foreach my $tick (@ticks) {
        $date = Date::Utility->new($tick->{date});
        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                epoch      => $date->epoch,
                quote      => $tick->{quote},
                bid        => $tick->{bid},
                ask        => $tick->{ask},
                underlying => $symbol,
            });
        }
        'Tick - ' . $date->datetime_yyyymmdd_hhmmss;
    }

    # insert 1 last tick, so the previous hour is aggregated
    $date = Date::Utility->new($date->epoch + 86400);
    lives_ok {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $date->epoch,
            quote      => 100.0,
            bid        => 100.0,
            ask        => 100.0,
            underlying => $symbol,
        });
    }
    'last dummy tick to aggregate previous hour - ' . $date->datetime_yyyymmdd_hhmmss;
};

my $underlying = BOM::Market::Underlying->new($symbol);
my $feed_api   = $underlying->feed_api;

subtest 'Daily OHLC' => sub {
    my $ohlcs = $feed_api->ohlc_start_end({
        start_time         => '2013-10-01',
        end_time           => '2013-12-07',
        aggregation_period => 86400,
    });
    isa_ok $ohlcs, 'ARRAY', 'Got daily ohlc for 2013-10-01 to 2013-12-07 and';
    is scalar @$ohlcs, 20, '20 OHLC found';

    subtest 'ohlc datatype' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            isa_ok $ohlc, 'Postgres::FeedDB::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_ohlc = 99999999999;
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch < $previous_ohlc, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_ohlc = $ohlc->epoch;
        }
    };

    subtest 'Daily ohlcs match' => sub {
        my $ohlc_value = {
            open  => 100.6,
            high  => 100.9,
            low   => 100.1,
            close => 100.5,
        };

        for (my $i = 0; $i < 20; $i++) {
            my $ohlc = pop @$ohlcs;
            my $date = $dates[$i];

            subtest "daily ohlc - $date" => sub {
                is($ohlc->epoch, Date::Utility->new($date)->epoch, 'time match');
                is($ohlc->open,  $ohlc_value->{open} + $i * 10,    'open match');
                is($ohlc->high,  $ohlc_value->{high} + $i * 10,    'high match');
                is($ohlc->low,   $ohlc_value->{low} + $i * 10,     'low match');
                is($ohlc->close, $ohlc_value->{close} + $i * 10,   'close match');
            };
        }
    };
};

subtest 'Weekly OHLC' => sub {
    my $ohlcs = $feed_api->ohlc_start_end({
        start_time         => '2013-10-07',
        end_time           => '2013-11-25',
        aggregation_period => 7 * 86400,
    });
    isa_ok $ohlcs, 'ARRAY', 'Got weekly ohlc for 2013-10-07 to 2013-11-25 and';
    is scalar @$ohlcs, 8, '8 OHLC found';

    subtest 'ohlc datatype' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            isa_ok $ohlc, 'Postgres::FeedDB::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_ohlc = 99999999999;
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch < $previous_ohlc, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_ohlc = $ohlc->epoch;
        }
    };

    my @weekly_ohlcs = (
        ['2013-11-25', 260.6, 270.9, 260.1, 270.5],
        ['2013-11-18', 250.6, 250.9, 250.1, 250.5],
        ['2013-11-11', 230.6, 240.9, 230.1, 240.5],
        ['2013-11-04', 210.6, 220.9, 210.1, 220.5],
        ['2013-10-28', 190.6, 200.9, 190.1, 200.5],
        ['2013-10-21', 180.6, 180.9, 180.1, 180.5],
        ['2013-10-14', 160.6, 170.9, 160.1, 170.5],
        ['2013-10-07', 130.6, 150.9, 130.1, 150.5]);

    for (my $i = 0; $i < scalar @$ohlcs; $i++) {
        my $ohlc_db     = $ohlcs->[$i];
        my $ohlc_result = $weekly_ohlcs[$i];

        subtest "weekly ohlc - $ohlc_result->[0]" => sub {
            is($ohlc_db->epoch, Date::Utility->new($ohlc_result->[0])->epoch, 'time match');
            is($ohlc_db->open,  $ohlc_result->[1],                            'open match');
            is($ohlc_db->high,  $ohlc_result->[2],                            'high match');
            is($ohlc_db->low,   $ohlc_result->[3],                            'low match');
            is($ohlc_db->close, $ohlc_result->[4],                            'close match');
        };
    }
};

subtest 'Monthly OHLC' => sub {
    my $ohlcs = $feed_api->ohlc_start_end({
        start_time         => '2013-10-01',
        end_time           => '2013-11-30',
        aggregation_period => 30 * 86400,
    });
    isa_ok $ohlcs, 'ARRAY', 'Got monthly ohlc for 2013-10-01 to 2013-11-30 and';
    is scalar @$ohlcs, 2, '2 OHLC found';

    subtest 'ohlc datatype' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            isa_ok $ohlc, 'Postgres::FeedDB::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_ohlc = 99999999999;
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch < $previous_ohlc, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_ohlc = $ohlc->epoch;
        }
    };

    my @monthly_ohlc = (['2013-11-01', 210.6, 270.9, 210.1, 270.5], 
        ['2013-10-01', 100.6, 200.9, 100.1, 200.5]);

    for (my $i = 0; $i < scalar @$ohlcs; $i++) {
        my $ohlc_db     = $ohlcs->[$i];
        my $ohlc_result = $monthly_ohlc[$i];

        subtest "monthly ohlc - $ohlc_result->[0]" => sub {
            is($ohlc_db->epoch, Date::Utility->new($ohlc_result->[0])->epoch, 'time match');
            is($ohlc_db->open,  $ohlc_result->[1],                            'open match');
            is($ohlc_db->high,  $ohlc_result->[2],                            'high match');
            is($ohlc_db->low,   $ohlc_result->[3],                            'low match');
            is($ohlc_db->close, $ohlc_result->[4],                            'close match');
        };
    }
};

subtest '2-Week OHLC' => sub {
    my $ohlcs = $feed_api->ohlc_start_end({
        start_time         => '2013-10-10',
        end_time           => '2013-11-30',
        aggregation_period => 2 * 7 * 86400,
    });
    isa_ok $ohlcs, 'ARRAY', 'Got 2-week ohlc for 2013-10-10 to 2013-11-30 and';
    is scalar @$ohlcs, 4, '4 OHLC found';

    subtest 'ohlc datatype' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            isa_ok $ohlc, 'Postgres::FeedDB::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_ohlc = 99999999999;
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch < $previous_ohlc, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_ohlc = $ohlc->epoch;
        }
    };

    my @two_week_ohlc = (
        ['2013-11-21', 250.6, 280.9, 250.1, 280.5],
        ['2013-11-07', 220.6, 240.9, 220.1, 240.5],
        ['2013-10-24', 180.6, 210.9, 180.1, 210.5],
        ['2013-10-10', 140.6, 170.9, 140.1, 170.5]);

    for (my $i = 0; $i < scalar @$ohlcs; $i++) {
        my $ohlc_db     = $ohlcs->[$i];
        my $ohlc_result = $two_week_ohlc[$i];

        subtest "2-week ohlc - $ohlc_result->[0]" => sub {
            is($ohlc_db->epoch, Date::Utility->new($ohlc_result->[0])->epoch, 'time match');
            is($ohlc_db->open,  $ohlc_result->[1],                            'open match');
            is($ohlc_db->high,  $ohlc_result->[2],                            'high match');
            is($ohlc_db->low,   $ohlc_result->[3],                            'low match');
            is($ohlc_db->close, $ohlc_result->[4],                            'close match');
        };
    }
};

subtest 'Hourly OHLC' => sub {
    my $ohlcs = $feed_api->ohlc_start_end({
        start_time         => '2013-10-10',
        end_time           => '2013-10-15',
        aggregation_period => 3600,
    });
    isa_ok $ohlcs, 'ARRAY', 'Got hourly ohlc for 2013-10-10 to 2013-10-15 and';
    is scalar @$ohlcs, 18, '18 OHLC found';

    subtest 'ohlc datatype' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            isa_ok $ohlc, 'Postgres::FeedDB::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_ohlc = 99999999999;
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch < $previous_ohlc, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_ohlc = $ohlc->epoch;
        }
    };

    my @hourly_ohlc = (
        ['2013-10-13 23:00:00', 150.5, 150.5, 150.5, 150.5],
        ['2013-10-13 21:00:00', 150.4, 150.4, 150.4, 150.4],
        ['2013-10-13 17:00:00', 150.3, 150.3, 150.3, 150.3],
        ['2013-10-13 14:00:00', 150.2, 150.2, 150.2, 150.2],
        ['2013-10-13 12:00:00', 150.1, 150.1, 150.1, 150.1],
        ['2013-10-13 11:00:00', 150.9, 150.9, 150.9, 150.9],
        ['2013-10-13 09:00:00', 150.8, 150.8, 150.8, 150.8],
        ['2013-10-13 05:00:00', 150.7, 150.7, 150.7, 150.7],
        ['2013-10-13 02:00:00', 150.6, 150.6, 150.6, 150.6],
        ['2013-10-10 23:00:00', 140.5, 140.5, 140.5, 140.5],
        ['2013-10-10 21:00:00', 140.4, 140.4, 140.4, 140.4],
        ['2013-10-10 17:00:00', 140.3, 140.3, 140.3, 140.3],
        ['2013-10-10 14:00:00', 140.2, 140.2, 140.2, 140.2],
    );

    for (my $i = 0; $i < scalar @hourly_ohlc; $i++) {
        my $ohlc_db     = $ohlcs->[$i];
        my $ohlc_result = $hourly_ohlc[$i];

        subtest "hourly ohlc - " . $ohlc_result->[0] => sub {
            is($ohlc_db->epoch, Date::Utility->new($ohlc_result->[0])->epoch, 'time match');
            is($ohlc_db->open,  $ohlc_result->[1],                            'open match');
            is($ohlc_db->high,  $ohlc_result->[2],                            'high match');
            is($ohlc_db->low,   $ohlc_result->[3],                            'low match');
            is($ohlc_db->close, $ohlc_result->[4],                            'close match');
        };
    }
};

# ohlc with limit for charting
subtest 'Daily OHLC with limit for charting' => sub {
    my $ohlcs = $feed_api->ohlc_start_end_with_limit_for_charting({
        start_time         => '2013-10-01',
        end_time           => '2013-12-07',
        aggregation_period => 86400,
        limit              => 10,
    });
    isa_ok $ohlcs, 'ARRAY', 'Got daily ohlc for 2013-10-01 to 2013-12-07 and';
    is scalar @$ohlcs, 10, '10 OHLC found';

    subtest 'ohlc datatype' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            isa_ok $ohlc, 'Postgres::FeedDB::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_ohlc = 99999999999;
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch < $previous_ohlc, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_ohlc = $ohlc->epoch;
        }
    };

    my @daily_ohlcs = (
        ['2013-12-07 00:00:00', 290.6, 290.9, 290.1, 290.5],
        ['2013-12-04 00:00:00', 280.6, 280.9, 280.1, 280.5],
        ['2013-11-30 00:00:00', 270.6, 270.9, 270.1, 270.5],
        ['2013-11-27 00:00:00', 260.6, 260.9, 260.1, 260.5],
        ['2013-11-22 00:00:00', 250.6, 250.9, 250.1, 250.5],
        ['2013-11-17 00:00:00', 240.6, 240.9, 240.1, 240.5],
        ['2013-11-13 00:00:00', 230.6, 230.9, 230.1, 230.5],
        ['2013-11-07 00:00:00', 220.6, 220.9, 220.1, 220.5],
        ['2013-11-04 00:00:00', 210.6, 210.9, 210.1, 210.5],
        ['2013-10-31 00:00:00', 200.6, 200.9, 200.1, 200.5],
    );

    for (my $i = 0; $i < scalar @$ohlcs; $i++) {
        my $ohlc_db     = $ohlcs->[$i];
        my $ohlc_result = $daily_ohlcs[$i];

        subtest "daily ohlc - $ohlc_result->[0]" => sub {
            is($ohlc_db->epoch, Date::Utility->new($ohlc_result->[0])->epoch, 'time match');
            is($ohlc_db->open,  $ohlc_result->[1],                            'open match');
            is($ohlc_db->high,  $ohlc_result->[2],                            'high match');
            is($ohlc_db->low,   $ohlc_result->[3],                            'low match');
            is($ohlc_db->close, $ohlc_result->[4],                            'close match');
        };
    }
};

subtest 'Weekly OHLC with limit for charting' => sub {
    my $ohlcs = $feed_api->ohlc_start_end_with_limit_for_charting({
        start_time         => '2013-10-07',
        end_time           => '2013-11-25',
        aggregation_period => 7 * 86400,
        limit              => 5,
    });
    isa_ok $ohlcs, 'ARRAY', 'Got weekly ohlc for 2013-10-07 to 2013-11-25 and';
    is scalar @$ohlcs, 5, '5 OHLC found';

    subtest 'ohlc datatype' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            isa_ok $ohlc, 'Postgres::FeedDB::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_ohlc = 99999999999;
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch < $previous_ohlc, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_ohlc = $ohlc->epoch;
        }
    };

    my @weekly_ohlcs = (
        ['2013-11-25', 260.6, 270.9, 260.1, 270.5],
        ['2013-11-18', 250.6, 250.9, 250.1, 250.5],
        ['2013-11-11', 230.6, 240.9, 230.1, 240.5],
        ['2013-11-04', 210.6, 220.9, 210.1, 220.5],
        ['2013-10-28', 190.6, 200.9, 190.1, 200.5],
    );

    for (my $i = 0; $i < scalar @$ohlcs; $i++) {
        my $ohlc_db     = $ohlcs->[$i];
        my $ohlc_result = $weekly_ohlcs[$i];

        subtest "weekly ohlc - $ohlc_result->[0]" => sub {
            is($ohlc_db->epoch, Date::Utility->new($ohlc_result->[0])->epoch, 'time match');
            is($ohlc_db->open,  $ohlc_result->[1],                            'open match');
            is($ohlc_db->high,  $ohlc_result->[2],                            'high match');
            is($ohlc_db->low,   $ohlc_result->[3],                            'low match');
            is($ohlc_db->close, $ohlc_result->[4],                            'close match');
        };
    }
};

subtest 'Monthly OHLC with limit for charting' => sub {
    my $ohlcs = $feed_api->ohlc_start_end_with_limit_for_charting({
        start_time         => '2013-10-01',
        end_time           => '2013-11-30',
        aggregation_period => 30 * 86400,
        limit              => 1,
    });
    isa_ok $ohlcs, 'ARRAY', 'Got monthly ohlc for 2013-10-01 to 2013-11-30 and';
    is scalar @$ohlcs, 1, '1 OHLC found';

    subtest 'ohlc datatype' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            isa_ok $ohlc, 'Postgres::FeedDB::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_ohlc = 99999999999;
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch < $previous_ohlc, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_ohlc = $ohlc->epoch;
        }
    };

    my @monthly_ohlc = (['2013-11-01', 210.6, 270.9, 210.1, 270.5],);

    my $ohlc_db     = $ohlcs->[0];
    my $ohlc_result = $monthly_ohlc[0];
    subtest "monthly ohlc - $ohlc_result->[0]" => sub {
        is($ohlc_db->epoch, Date::Utility->new($ohlc_result->[0])->epoch, 'time match');
        is($ohlc_db->open,  $ohlc_result->[1],                            'open match');
        is($ohlc_db->high,  $ohlc_result->[2],                            'high match');
        is($ohlc_db->low,   $ohlc_result->[3],                            'low match');
        is($ohlc_db->close, $ohlc_result->[4],                            'close match');
    };
};

subtest '2-Week OHLC with limit for charting' => sub {
    my $ohlcs = $feed_api->ohlc_start_end_with_limit_for_charting({
        start_time         => '2013-10-10',
        end_time           => '2013-11-30',
        aggregation_period => 2 * 7 * 86400,
        limit              => 3,
    });
    isa_ok $ohlcs, 'ARRAY', 'Got 2-week ohlc for 2013-10-10 to 2013-11-30 and';
    is scalar @$ohlcs, 3, '3 OHLC found';

    subtest 'ohlc datatype' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            isa_ok $ohlc, 'Postgres::FeedDB::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_ohlc = 99999999999;
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch < $previous_ohlc, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_ohlc = $ohlc->epoch;
        }
    };

    my @two_week_ohlc =
        (['2013-11-21', 250.6, 280.9, 250.1, 280.5], 
            ['2013-11-07', 220.6, 240.9, 220.1, 240.5], 
            ['2013-10-24', 180.6, 210.9, 180.1, 210.5],);

    for (my $i = 0; $i < scalar @$ohlcs; $i++) {
        my $ohlc_db     = $ohlcs->[$i];
        my $ohlc_result = $two_week_ohlc[$i];

        subtest "2-week ohlc - $ohlc_result->[0]" => sub {
            is($ohlc_db->epoch, Date::Utility->new($ohlc_result->[0])->epoch, 'time match');
            is($ohlc_db->open,  $ohlc_result->[1],                            'open match');
            is($ohlc_db->high,  $ohlc_result->[2],                            'high match');
            is($ohlc_db->low,   $ohlc_result->[3],                            'low match');
            is($ohlc_db->close, $ohlc_result->[4],                            'close match');
        };
    }
};

subtest 'Hourly OHLC with limit for charting' => sub {
    my $ohlcs = $feed_api->ohlc_start_end_with_limit_for_charting({
        start_time         => '2013-10-10',
        end_time           => '2013-10-15',
        aggregation_period => 3600,
        limit              => 5,
    });
    isa_ok $ohlcs, 'ARRAY', 'Got hourly ohlc for 2013-10-10 to 2013-10-15 and';
    is scalar @$ohlcs, 5, '5 OHLC found';

    subtest 'ohlc datatype' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            isa_ok $ohlc, 'Postgres::FeedDB::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_ohlc = 99999999999;
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch < $previous_ohlc, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_ohlc = $ohlc->epoch;
        }
    };

    my @hourly_ohlc = (
        ['2013-10-13 23:00:00', 150.5, 150.5, 150.5, 150.5],
        ['2013-10-13 21:00:00', 150.4, 150.4, 150.4, 150.4],
        ['2013-10-13 17:00:00', 150.3, 150.3, 150.3, 150.3],
        ['2013-10-13 14:00:00', 150.2, 150.2, 150.2, 150.2],
        ['2013-10-13 12:00:00', 150.1, 150.1, 150.1, 150.1],
    );

    for (my $i = 0; $i < scalar @$ohlcs; $i++) {
        my $ohlc_db     = $ohlcs->[$i];
        my $ohlc_result = $hourly_ohlc[$i];

        subtest "hourly ohlc - $ohlc_result->[0]" => sub {
            is($ohlc_db->epoch, Date::Utility->new($ohlc_result->[0])->epoch, 'time match');
            is($ohlc_db->open,  $ohlc_result->[1],                            'open match');
            is($ohlc_db->high,  $ohlc_result->[2],                            'high match');
            is($ohlc_db->low,   $ohlc_result->[3],                            'low match');
            is($ohlc_db->close, $ohlc_result->[4],                            'close match');
        };
    }
};

subtest 'OHLC Start-End - no data available' => sub {
    my $ohlcs = $feed_api->ohlc_start_end({
        start_time         => '2012-03-15',
        end_time           => '2012-04-15',
        aggregation_period => 86400
    });
    isa_ok $ohlcs, 'ARRAY', 'Got ohlcs for 2012-03-15 to 2012-04-15 and';
    is scalar @$ohlcs, 0, '0 ohlc found';
};

subtest 'OHLC Start-End - Sanity Check ' => sub {
    throws_ok {
        warning_like {
            my $ohlcs = $feed_api->ohlc_start_end({
                end_time           => '2012-05-15 23:00:00',
                aggregation_period => 86400
            });
        }
        qr/Error sanity_checks_start_end: start time(<NULL>) and end time(2012-05-15 23:00:00) should be provided/;
    }
    qr/Error sanity_checks_start_end: start time\(<NULL>\) and end time\(2012-05-15 23:00:00\) should be provided/,
        'No Start Time -  We don\'t entertain such queries';

    throws_ok {
        warnings_like {
            my $ohlcs = $feed_api->ohlc_start_end({
                start_time         => '2012-05-22 00:00:00',
                aggregation_period => 2 * 86400
            });
        }
        qr/Error sanity_checks_start_end: start time\(2012-05-22 00:00:00\) and end time\(<NULL>\) should be provided/;
    }
    qr/Error sanity_checks_start_end: start time\(2012-05-22 00:00:00\) and end time\(<NULL>\) should be provided/,
        'No End Time -  We don\'t entertain such queries';

    throws_ok {
        warnings_like {
            my $ohlcs = $feed_api->ohlc_start_end({
                start_time         => '2012-05-22 00:00:00',
                end_time           => '2012-05-15 23:00:00',
                aggregation_period => 14 * 86400
            });
        }
        qr/Error sanity_checks_start_end: end time\(2012-05-22 00:00:00\) < start time\(2012-05-15 23:00:00\)/;
    }
    qr/Error sanity_checks_start_end: end time\(1337122800\) < start time\(1337644800\)/, 'end time should be > start time';
};

done_testing;
