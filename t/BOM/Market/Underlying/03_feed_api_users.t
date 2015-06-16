use Test::Most;
use Test::MockTime qw( :all );
use Test::FailWarnings;
use Test::MockObject;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );

use Date::Utility;
use BOM::Market::Underlying;
use Cache::RedisDB;
use BOM::Database::FeedDB;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/FOREX NYSE EURONEXT/);

subtest 'get_combined_realtime' => sub {
    #Rewind back to a simpler time.
    my $test_time = Date::Utility->new('2012-09-28 20:59:59');
    Test::MockTime::set_absolute_time($test_time->epoch);

    my $orig_cache;
    subtest 'Empty redis cache for frxUSDJPY' => sub {
        my $cache = Cache::RedisDB->get('COMBINED_REALTIME', 'frxUSDJPY');
        $orig_cache = $cache;
        lives_ok {
            Cache::RedisDB->set_nw('COMBINED_REALTIME', 'frxUSDJPY', undef);
        }
        'We are able to set COMBINED_REALTIME to undef';

        $cache = Cache::RedisDB->get('COMBINED_REALTIME', 'frxUSDJPY');
        ok !$cache, 'COMBINED_REALTIME is now empty';
    };

    my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxUSDJPY'}]);
    subtest 'Fetch from empty cache' => sub {
        my $cache = Cache::RedisDB->get('COMBINED_REALTIME', 'frxUSDJPY');
        ok !$cache, 'Nothing is available on cache';

    };

    subtest 'call with no data' => sub {
        subtest 'call' => sub {
            my $realtime;
            lives_ok {
                $realtime = $underlying->get_combined_realtime;
            }
            'get_combined_realtime call on empty does not crash';

            ok !$realtime, 'Is there a realtime tick';
        };

        subtest 'relatives' => sub {
            my $spot = $underlying->spot;

            is $spot, undef, 'no spot';
            is $underlying->spot_time, undef, 'no spot time';
        };
    };

    subtest 'Tick at t' => sub {
        my $tick = {
            epoch => $test_time->epoch,
            quote => 79.873,
            bid   => 100.2,
            ask   => 100.4
        };
        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);
        }
        'Tick Inserted';
    };

    subtest 'Call with data at t and now at t' => sub {
        my $cache = Cache::RedisDB->get('COMBINED_REALTIME', 'frxUSDJPY');
        ok !$cache, 'Nothing is available on cache';

        my $realtime;
        lives_ok {
            $realtime = $underlying->get_combined_realtime;
        }
        'get_combined_realtime call on empty does not crash';

        ok $realtime, 'there is a realtime tick';
    };

    # We move to a weekend when the market is closed.
    Test::MockTime::set_absolute_time($test_time->epoch + 86400);

    subtest 'call with data at t and now at t + 86400' => sub {
        subtest 'Direct' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxUSDJPY'}]);

            my $realtime;
            lives_ok {
                $realtime = $underlying->get_combined_realtime;
            }
            'get_combined_realtime call does not crash';

            ok $realtime, 'Got some realtime data';
            is $realtime->{epoch}, $test_time->epoch, 'Got the correct tick epoch';
            is $realtime->{quote}, 79.873, 'Correct quote';
        };

        subtest 'Inverted' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxJPYUSD'}]);

            my $realtime;
            lives_ok {
                $realtime = $underlying->get_combined_realtime;
            }
            'get_combined_realtime call does not crash';

            ok $realtime, 'Got some realtime data';
            is $realtime->{epoch}, $test_time->epoch, 'Got the correct tick epoch';
            is $realtime->{quote}, 1 / 79.873, 'Correct quote';
        };

        subtest 'Redis Cache' => sub {
            my $cache = Cache::RedisDB->get('COMBINED_REALTIME', 'frxUSDJPY');
            ok $cache, 'Cache is not empty anymore';
        };

        subtest 'Relatives' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxUSDJPY'}]);
            cmp_ok($underlying->spot, '==', 79.873, 'spot is correct');
            is $underlying->spot_time, $test_time->epoch, 'spot time is correct';
        };
    };

    subtest 'Tick for t + 1 seconds' => sub {
        my $new_tick = {
            epoch => ($test_time->epoch + 1),
            quote => 79.883,
            bid   => 100.2,
            ask   => 100.4
        };
        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($new_tick);
        }
        'Tick - Start of day';
    };

    subtest 'call with data at t + 1 and now at t + 86400' => sub {
        subtest 'Direct' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxUSDJPY'}]);

            my $realtime;
            lives_ok {
                $realtime = $underlying->get_combined_realtime;
            }
            'get_combined_realtime call does not crash';

            ok $realtime, 'Got some realtime data';
            is $realtime->{epoch}, $test_time->epoch, 'Got the correct tick epoch';
            is $realtime->{quote}, 79.873, 'Correct quote';
        };

        subtest 'Inverted' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxJPYUSD'}]);

            my $realtime;
            lives_ok {
                $realtime = $underlying->get_combined_realtime;
            }
            'get_combined_realtime call does not crash';

            ok $realtime, 'Got some realtime data';
            is $realtime->{epoch}, $test_time->epoch, 'Got the correct tick epoch';
            is $realtime->{quote}, 1 / 79.873, 'Correct quote';
        };
    };

    # Reset Redis to original value
    Cache::RedisDB->set_nw('COMBINED_REALTIME', 'frxUSDJPY', $orig_cache);
    Test::MockTime::restore_time();
};

subtest 'next_tick_after' => sub {
    my $test_time = Date::Utility->new('2012-01-12 03:23:05');
    subtest 'call with no data' => sub {
        subtest 'Direct' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxGBPAUD'}]);

            my $tick = $underlying->next_tick_after($test_time->epoch);
            ok !$tick, 'No tick';
        };

        subtest 'Inverted' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxAUDGBP'}]);

            my $tick = $underlying->next_tick_after($test_time->epoch);
            ok !$tick, 'No tick';
        };
    };

    subtest 'Tick at t - 1 second' => sub {
        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                epoch      => ($test_time->epoch - 1),
                quote      => 1.5056,
                bid        => 1.5055,
                ask        => 1.5057,
                underlying => 'frxGBPAUD'
            });
        }
        'Tick - Start of day';
    };

    subtest 'call with data at t - 1 second' => sub {
        subtest 'Direct' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxGBPAUD'}]);

            my $tick = $underlying->next_tick_after($test_time->epoch);
            ok !$tick, 'No tick';
        };

        subtest 'Inverted' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxAUDGBP'}]);

            my $tick = $underlying->next_tick_after($test_time->epoch);
            ok !$tick, 'No tick';
        };
    };

    subtest 'Tick at time t' => sub {
        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                epoch      => $test_time->epoch,
                quote      => 1.5056,
                bid        => 1.5055,
                ask        => 1.5057,
                underlying => 'frxGBPAUD'
            });
        }
        'Tick - Start of day';
    };

    subtest 'call with data at t' => sub {
        subtest 'Direct' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxGBPAUD'}]);

            my $tick = $underlying->next_tick_after($test_time->epoch);
            ok !$tick, 'No tick';
        };

        subtest 'Inverted' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxAUDGBP'}]);

            my $tick = $underlying->next_tick_after($test_time->epoch);
            ok !$tick, 'No tick';
        };
    };

    subtest 'Tick at t + 1 seconds' => sub {
        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                epoch      => ($test_time->epoch + 1),
                quote      => 1.5062,
                bid        => 1.5059,
                ask        => 1.5070,
                underlying => 'frxGBPAUD'
            });
        }
        'Tick - Start of day';
    };

    subtest 'call with data at t + 1 seconds' => sub {
        subtest 'Direct' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxGBPAUD'}]);

            my $tick = $underlying->next_tick_after($test_time->epoch);
            ok $tick, 'There are ticks';

            my $tick_date = Date::Utility->new({epoch => $tick->epoch});
            is $tick_date->datetime_yyyymmdd_hhmmss, '2012-01-12 03:23:06', 'Correct time';
            is $tick->quote, 1.5062, 'Correct quote';
        };

        subtest 'Inverted' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxAUDGBP'}]);

            my $tick = $underlying->next_tick_after($test_time->epoch);
            ok $tick, 'There are ticks';

            my $tick_date = Date::Utility->new({epoch => $tick->epoch});
            is $tick_date->datetime_yyyymmdd_hhmmss, '2012-01-12 03:23:06', 'Correct time';
            is $tick->quote, 1 / 1.5062, 'Correct quote';
        };
    };

    subtest 'Direct date query' => sub {
        my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxGBPAUD'}]);

        my $tick = $underlying->next_tick_after('12-Jan-12 03:23:05');
        ok $tick, 'There are ticks';

        my $tick_date = Date::Utility->new({epoch => $tick->epoch});
        is $tick_date->datetime_yyyymmdd_hhmmss, '2012-01-12 03:23:06', 'Correct time';
        is $tick->quote, 1.5062, 'Correct quote';
    };
};

subtest 'tick_at' => sub {

    my $test_time = Date::Utility->new('2012-09-28 20:59:59');
    subtest 'call with no data' => sub {
        subtest 'Direct' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxAUDJPY'}]);

            ok !$underlying->tick_at($test_time->epoch), 'Got Nothing';
        };

        subtest 'Inverted' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxJPYAUD'}]);

            ok !$underlying->tick_at($test_time->epoch), 'Got Nothing';
        };
    };

    subtest 'Adding tick for t - 20 mins' => sub {
        my $tick_date = Date::Utility->new('2012-09-28 20:39:59');
        my $tick      = {
            epoch      => $tick_date->epoch,
            quote      => 80.33,
            bid        => 80.845,
            ask        => 80.895,
            underlying => 'frxAUDJPY'
        };

        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);
        }
        'Tick - Last tick for the day';
    };

    subtest 'call with data at t - 20 mins' => sub {
        subtest 'Direct' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxAUDJPY'}]);

            ok !$underlying->tick_at($test_time->epoch), 'Got Nothing';
        };

        subtest 'Inverted' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxJPYAUD'}]);

            ok !$underlying->tick_at($test_time->epoch), 'Got Nothing';
        };
    };

    subtest 'Adding tick for t' => sub {
        my $tick = {
            epoch      => $test_time->epoch,
            quote      => 80.88,
            bid        => 80.845,
            ask        => 80.895,
            underlying => 'frxAUDJPY'
        };

        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);
        }
        'Tick - Last tick for the day';
    };

    subtest 'call with data at t' => sub {
        subtest 'Direct' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxAUDJPY'}]);

            my $tick = $underlying->tick_at($test_time->epoch);
            is $tick->quote, 80.88, 'Got the right price';
        };

        subtest 'Inverted' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxJPYAUD'}]);

            my $tick = $underlying->tick_at($test_time->epoch);
            is $tick->quote, 1 / 80.88, 'Got the right price';
        };
    };

    subtest 'Adding tick for t + 5' => sub {
        my $tick_date = Date::Utility->new('2012-09-28 21:05:00');
        my $tick      = {
            epoch      => $tick_date->epoch,
            quote      => 80.73,
            bid        => 80.845,
            ask        => 80.895,
            underlying => 'frxAUDJPY'
        };

        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);
        }
        'Tick - Last tick for the day';
    };

    subtest 'call with data at t + 5' => sub {
        subtest 'Direct' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxAUDJPY'}]);

            my $tick = $underlying->tick_at($test_time->epoch);
            is $tick->quote, 80.88, 'Got the right price';
        };

        subtest 'Inverted' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxJPYAUD'}]);

            my $tick = $underlying->tick_at($test_time->epoch);
            is $tick->quote, 1 / 80.88, 'Got the right price';
        };
    };
};

subtest 'tick_at scenarios' => sub {
    subtest 'one more tick to succeed' => sub {
        my $tick_date = Date::Utility->new('2012-09-28 07:55:00');
        my $tick      = {
            epoch      => $tick_date->epoch,
            quote      => 6080.73,
            underlying => 'frxEURGBP'
        };
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);

        subtest 'Tick not available' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxEURGBP'}]);
            my $test_time = Date::Utility->new('2012-09-28 07:57:00');

            ok !$underlying->tick_at($test_time->epoch), 'No price as we are not sure if there is another tick coming';
            is $underlying->tick_at($test_time->epoch, {allow_inconsistent => 1})->quote, 6080.73,
                'If we are ok with inconsistent price then get last available tick';
        };

        subtest 'tick at exact time' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxEURGBP'}]);
            my $test_time = Date::Utility->new('2012-09-28 07:55:00');
            is $underlying->tick_at($test_time->epoch)->quote, 6080.73, 'Since you are asking for the exact time. We have it';
        };

        $tick_date = Date::Utility->new('2012-09-28 07:58:00');
        $tick      = {
            epoch      => $tick_date->epoch,
            quote      => 6088.73,
            underlying => 'frxEURGBP'
        };
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);

        subtest 'Tick now available' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxEURGBP'}]);
            my $test_time = Date::Utility->new('2012-09-28 07:57:00');

            is $underlying->tick_at($test_time->epoch)->quote, 6080.73, 'Since we have atleast one more tick we are ok to give last available tick';
            is $underlying->tick_at($test_time->epoch, {allow_inconsistent => 1})->quote, 6080.73,
                'If we are ok with inconsistent price then get last available tick';
        };
    };

    subtest 'forced ohlc aggregation to succeed' => sub {
        subtest 'OHLC not aggregated' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxEURGBP'}]);
            my $test_time = Date::Utility->new('2012-09-28 07:59:00');

            ok !$underlying->tick_at($test_time->epoch), 'No price as we are not sure if there is another tick coming';
            is $underlying->tick_at($test_time->epoch, {allow_inconsistent => 1})->quote, 6088.73,
                'If we are ok with inconsistent price then get last available tick';
        };

        subtest 'tick at exact time' => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxEURGBP'}]);
            my $test_time = Date::Utility->new('2012-09-28 07:58:00');
            is $underlying->tick_at($test_time->epoch)->quote, 6088.73, 'Since you are asking for the exact time. We have it';
        };

        subtest 'force Ohlc aggregation' => sub {
            my $dbh = BOM::Database::FeedDB::write_dbh;
            $dbh->{PrintError} = 0;
            $dbh->{RaiseError} = 1;
            my $query     = qq{UPDATE feed.ohlc_status set last_time = ? where underlying = 'frxEURGBP'};
            my $statement = $dbh->prepare($query);

            ok $statement, 'Statement Prepared';
            $statement->bind_param(1, "2012/09/28 08:00:00");
            ok $statement->execute, 'Able to Update';
        };

        subtest "OHLC aggregated" => sub {
            my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxEURGBP'}]);
            my $test_time = Date::Utility->new('2012-09-28 07:59:00');

            is $underlying->tick_at($test_time->epoch)->quote, 6088.73, 'Since the ticks are already aggregated, we will not get any more ticks';
            is $underlying->tick_at($test_time->epoch, {allow_inconsistent => 1})->quote, 6088.73,
                'If we are ok with inconsistent price then get last available tick';
        };
    };

    subtest 'next day tick' => sub {
        my $tick_date = Date::Utility->new('2012-10-01 03:20:00');
        my $tick      = {
            epoch      => $tick_date->epoch,
            quote      => 6077.22,
            underlying => 'frxEURGBP'
        };
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);

        my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxEURGBP'}]);
        my $test_time = Date::Utility->new('2012-10-01 03:10:00');

        is $underlying->tick_at($test_time->epoch)->quote, 6088.73, 'The last available tick is from previous day';
        is $underlying->tick_at($test_time->epoch, {allow_inconsistent => 1})->quote, 6088.73,
            'If we are ok with inconsistent price then get last available tick';
    };
};

subtest 'get_ohlc_data_for_period' => sub {
    subtest 'Invalid dates' => sub {
        my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'DJI'}]);

        throws_ok {
            $underlying->get_ohlc_data_for_period({
                start => '2012-10-20',
                end   => '2012-10-15'
            });
        }
        qr/\[get_ohlc_data_for_period\] start_date > end_date/, 'Exceptions Exceptions';
    };

    subtest 'no data' => sub {
        my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'DJI'}]);
        my @ohlc = $underlying->get_ohlc_data_for_period({
            start => '2012-10-22',
            end   => '2012-10-24'
        });

        ok !@ohlc, 'ohlc is undef';
    };

    my $ohlc_date = Date::Utility->new('2012-10-22');
    my $ohlc      = {
        epoch      => $ohlc_date->epoch,
        open       => 13_344.28,
        high       => 13_368.55,
        low        => 13_235.15,
        close      => 13_345.89,
        underlying => 'DJI'
    };
    BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily($ohlc);

    $ohlc_date = Date::Utility->new('2012-10-23');
    $ohlc      = {
        epoch      => $ohlc_date->epoch,
        open       => 13_344.90,
        high       => 13_344.90,
        low        => 13_083.28,
        close      => 13_102.53,
        underlying => 'DJI'
    };
    BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily($ohlc);

    $ohlc_date = Date::Utility->new('2012-10-24');
    $ohlc      = {
        epoch      => $ohlc_date->epoch,
        open       => 13_103.53,
        high       => 13_155.21,
        low        => 13_063.63,
        close      => 13_077.34,
        underlying => 'DJI'
    };
    BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily($ohlc);

    subtest 'high, low calculation' => sub {
        my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'DJI'}]);
        my $ohlc = $underlying->get_high_low_for_period({
            start => '2012-10-22',
            end   => '2012-10-24'
        });

        is $ohlc->{high}, 13_368.55, 'Correct High';
        is $ohlc->{low},  13_063.63, 'Correct Low';
        my $ohlc_table = $underlying->get_daily_ohlc_table({
            start => '2012-10-22',
            end   => '2012-10-24'
        });
        is scalar @{$ohlc_table}, 3, 'The three ticks are in table';
    };

    my $tick_date = Date::Utility->new('2012-10-23 14:35:00');
    my $tick      = {
        epoch      => $tick_date->epoch,
        quote      => 13_220.73,
        underlying => 'DJI'
    };

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);

    subtest 'high, low calculation from ticks' => sub {
        my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'DJI'}]);
        my $ohlc = $underlying->get_high_low_for_period({
            start => '2012-10-22',
            end   => '2012-10-23 22:00:00'
        });

        is $ohlc->{high}, 13_368.55, 'Correct High';
        is $ohlc->{low},  13_220.73, 'Correct Low';
        my $ohlc_table = $underlying->get_daily_ohlc_table({
            start => '2012-10-22',
            end   => '2012-10-23 22:00:00'
        });

        is scalar @{$ohlc_table}, 2, 'The two ticks are in table';
    };
};

subtest 'price_at_intervals' => sub {
    my $tick_date = Date::Utility->new('2013-04-22 10:00:00');
    my $tick      = {
        epoch      => $tick_date->epoch,
        quote      => 5_055.2,
        underlying => 'AEX'
    };

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);

    $tick_date = Date::Utility->new('2013-04-22 10:03:00');
    $tick      = {
        epoch      => $tick_date->epoch,
        quote      => 5_080.2,
        underlying => 'AEX'
    };

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);

    $tick_date = Date::Utility->new('2013-04-22 10:08:00');
    $tick      = {
        epoch      => $tick_date->epoch,
        quote      => 5_033.9,
        underlying => 'AEX'
    };

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);

    $tick_date = Date::Utility->new('2013-04-22 10:12:00');
    $tick      = {
        epoch      => $tick_date->epoch,
        quote      => 4_923.4,
        underlying => 'AEX'
    };

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);
    my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'AEX'}]);

    subtest 'Basic' => sub {
        my $prices = $underlying->price_at_intervals({
            start_time       => '2013-04-22 10:00:00',
            end_time         => '2013-04-22 10:10:00',
            interval_seconds => 300
        });

        is scalar @$prices, 3, 'Got 3 prices';
        is $prices->[0]->{epoch}, Date::Utility->new('2013-04-22 10:00:00')->{epoch}, "First tick time";
        is $prices->[0]->{quote}, '5055.20', "First tick spot";
        is $prices->[2]->{epoch}, Date::Utility->new('2013-04-22 10:10:00')->{epoch}, "Last tick time";
        is $prices->[2]->{quote}, '5033.90', "Last tick spot";
    };

    subtest 'Overtime' => sub {
        my $prices = $underlying->price_at_intervals({
            start_time       => '2013-04-22 10:00:00',
            end_time         => '2013-04-22 10:30:00',
            interval_seconds => 300
        });

        is scalar @$prices, 3, 'Got 3 prices';
        is $prices->[0]->{epoch}, Date::Utility->new('2013-04-22 10:00:00')->{epoch}, "First tick time";
        is $prices->[0]->{quote}, '5055.20', "First tick spot";
        is $prices->[1]->{epoch}, Date::Utility->new('2013-04-22 10:05:00')->{epoch}, "Second tick time";
        is $prices->[1]->{quote}, '5080.20', "Second tick spot";
        is $prices->[2]->{epoch}, Date::Utility->new('2013-04-22 10:10:00')->{epoch}, "Last tick time";
        is $prices->[2]->{quote}, '5033.90', "Last tick spot";
    };

    subtest 'Other time' => sub {
        my $prices = $underlying->price_at_intervals({
            start_time       => '2013-04-22 10:50:00',
            end_time         => '2013-04-22 11:30:00',
            interval_seconds => 300
        });

        is scalar @$prices, 0, 'Got 0 prices';
    };

    subtest 'End time < Start Time' => sub {
        my $prices = $underlying->price_at_intervals({
            start_time       => '2013-04-22 10:50:00',
            end_time         => '2013-04-22 10:30:00',
            interval_seconds => 300
        });
        is scalar @$prices, 0, 'Got 0 prices';
    };

    subtest 'Start time == End Time' => sub {
        my $prices = $underlying->price_at_intervals({
            start_time       => '2013-04-22 10:00:00',
            end_time         => '2013-04-22 10:00:00',
            interval_seconds => 300
        });

        is scalar @$prices, 1, 'Got 1 prices';
        is $prices->[0]->{epoch}, Date::Utility->new('2013-04-22 10:00:00')->{epoch}, "Tick time";
        is $prices->[0]->{quote}, '5055.20', "Tick spot";
    };

    subtest 'start_time before ticks' => sub {
        my $prices = $underlying->price_at_intervals({
            start_time       => '2013-04-22 08:00:00',
            end_time         => '2013-04-22 10:00:00',
            interval_seconds => 300
        });

        is scalar @$prices, 1, 'Got 1 prices';
        is $prices->[0]->{epoch}, Date::Utility->new('2013-04-22 10:00:00')->{epoch}, "Tick time";
        is $prices->[0]->{quote}, '5055.20', "Tick spot";
    };
};

done_testing;
