use strict;
use warnings;

use Test::Most;
use Test::MockTime qw( :all );
use Test::FailWarnings;
use Test::MockObject;
use Test::MockModule;
use File::Spec;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;

use Date::Utility;
use BOM::MarketData qw(create_underlying);
use Cache::RedisDB;
use Postgres::FeedDB;
use Postgres::FeedDB::Spot::OHLC;

subtest 'get_combined_realtime' => sub {
    #Rewind back to a simpler time.
    my $test_time = Date::Utility->new('2012-09-28 20:59:59');
    Test::MockTime::set_absolute_time($test_time->epoch);

    my $orig_cache;
    subtest 'Empty redis cache for frxUSDJPY' => sub {
        my $cache = Cache::RedisDB->get('QUOTE', 'frxUSDJPY');
        $orig_cache = $cache;
        lives_ok {
            Cache::RedisDB->set_nw('QUOTE', 'frxUSDJPY', undef);
        }
        'We are able to set QUOTE to undef';

        $cache = Cache::RedisDB->get('QUOTE', 'frxUSDJPY');
        ok !$cache, 'QUOTE is now empty';
    };

    subtest 'Empty redis cache for frxJPYUSD' => sub {
        my $cache = Cache::RedisDB->get('QUOTE', 'frxJPYUSD');
        $orig_cache = $cache;
        lives_ok {
            Cache::RedisDB->set_nw('QUOTE', 'frxJPYUSD', undef);
        }
        'We are able to set QUOTE to undef';

        $cache = Cache::RedisDB->get('QUOTE', 'frxJPYUSD');
        ok !$cache, 'QUOTE is now empty';
    };

    my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxUSDJPY'}]);
    subtest 'Fetch from empty cache' => sub {
        my $cache = Cache::RedisDB->get('QUOTE', 'frxUSDJPY');
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
        my $cache = Cache::RedisDB->get('QUOTE', 'frxUSDJPY');
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
            my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxUSDJPY'}]);

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
            my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxJPYUSD'}]);

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
            my $cache = Cache::RedisDB->get('QUOTE', 'frxUSDJPY');
            ok $cache, 'Cache is not empty anymore';
        };

        subtest 'Relatives' => sub {
            my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxUSDJPY'}]);
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
            my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxUSDJPY'}]);

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
            my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxJPYUSD'}]);

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
    Cache::RedisDB->set_nw('QUOTE', 'frxUSDJPY', $orig_cache);
    Test::MockTime::restore_time();
};

subtest 'next_tick_after' => sub {
    my $test_time = Date::Utility->new('2012-01-12 03:23:05');
    subtest 'call with no data' => sub {
        subtest 'Direct' => sub {
            my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxGBPAUD'}]);

            my $tick = $underlying->next_tick_after($test_time->epoch);
            ok !$tick, 'No tick';
        };

        subtest 'Inverted' => sub {
            my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxAUDGBP'}]);

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
            my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxGBPAUD'}]);

            my $tick = $underlying->next_tick_after($test_time->epoch);
            ok !$tick, 'No tick';
        };

        subtest 'Inverted' => sub {
            my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxAUDGBP'}]);

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
            my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxGBPAUD'}]);

            my $tick = $underlying->next_tick_after($test_time->epoch);
            ok !$tick, 'No tick';
        };

        subtest 'Inverted' => sub {
            my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxAUDGBP'}]);

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
            my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxGBPAUD'}]);

            my $tick = $underlying->next_tick_after($test_time->epoch);
            ok $tick, 'There are ticks';

            my $tick_date = Date::Utility->new({epoch => $tick->epoch});
            is $tick_date->datetime_yyyymmdd_hhmmss, '2012-01-12 03:23:06', 'Correct time';
            is $tick->quote, 1.5062, 'Correct quote';
        };

        subtest 'Inverted' => sub {
            my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxAUDGBP'}]);

            my $tick = $underlying->next_tick_after($test_time->epoch);
            ok $tick, 'There are ticks';

            my $tick_date = Date::Utility->new({epoch => $tick->epoch});
            is $tick_date->datetime_yyyymmdd_hhmmss, '2012-01-12 03:23:06', 'Correct time';
            is $tick->quote, 1 / 1.5062, 'Correct quote';
        };
    };

    subtest 'Direct date query' => sub {
        my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxGBPAUD'}]);

        my $tick = $underlying->next_tick_after('12-Jan-12 03:23:05');
        ok $tick, 'There are ticks';

        my $tick_date = Date::Utility->new({epoch => $tick->epoch});
        is $tick_date->datetime_yyyymmdd_hhmmss, '2012-01-12 03:23:06', 'Correct time';
        is $tick->quote, 1.5062, 'Correct quote';
    };
};

subtest 'tick_at' => sub {

    my $test_time           = Date::Utility->new('2012-09-28 20:59:59');
    my $underlying          = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxAUDJPY'}]);
    my $inverted_underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxJPYAUD'}]);

    subtest 'call with no data' => sub {
        ok !$underlying->spot_source->tick_at($test_time),          'Standard got nothing';
        ok !$inverted_underlying->spot_source->tick_at($test_time), '... and so did inverted';
    };

    subtest 'Adding tick for t - 20 mins' => sub {
        my $tick = {
            epoch      => $test_time->minus_time_interval('20m')->epoch,
            quote      => 80.33,
            bid        => 80.845,
            ask        => 80.895,
            underlying => $underlying->symbol,
        };

        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);
        }
        'Tick added.';
    };

    subtest 'call for t with data at t - 20 mins' => sub {
        ok !$underlying->spot_source->tick_at($test_time),          'Standard got nothing';
        ok !$inverted_underlying->spot_source->tick_at($test_time), '... and so did inverted';
    };

    subtest 'Adding tick for t' => sub {
        my $tick = {
            epoch      => $test_time->epoch,
            quote      => 80.88,
            bid        => 80.845,
            ask        => 80.895,
            underlying => $underlying->symbol,
        };

        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);
        }
        'Tick added';
    };

    subtest 'call for t with data at t' => sub {
        is $underlying->spot_source->tick_at($test_time)->quote, 80.88, 'Standard got correct quote';
        is $inverted_underlying->spot_source->tick_at($test_time)->quote, 1 / 80.88, '... and so did inverted';
    };

    subtest 'Adding tick for t + 5 minutes, 1 second' => sub {
        my $tick = {
            epoch      => $test_time->plus_time_interval('5m1s')->epoch,
            quote      => 80.73,
            bid        => 80.845,
            ask        => 80.895,
            underlying => $underlying->symbol,
        };

        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);
        }
        'Tick added';
    };

    subtest 'call for t with data at t + 5 minutes, 1 second' => sub {
        is $underlying->spot_source->tick_at($test_time)->quote, 80.88, 'Standard got correct quote';
        is $inverted_underlying->spot_source->tick_at($test_time)->quote, 1 / 80.88, '... and so did inverted';
    };
};

subtest 'tick_at scenarios' => sub {
    my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxEURGBP'}]);
    my $first_tick_date = Date::Utility->new('2012-09-28 07:55:00');
    subtest 'one more tick to succeed' => sub {
        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick(

                {
                    epoch      => $first_tick_date->epoch,
                    quote      => 6080.73,
                    underlying => $underlying->symbol,
                }

                )
        }
        'Added first tick';

        subtest 'Request for 2 minutes after first tick' => sub {
            my $test_time = $first_tick_date->plus_time_interval('2m');

            ok !$underlying->spot_source->tick_at($test_time), 'No price as we are not sure if there is another tick coming';
            is $underlying->spot_source->tick_at($test_time, {allow_inconsistent => 1})->quote, 6080.73,
                'If we are ok with inconsistent price then get our tick';
        };

        subtest 'tick at exact time' => sub {
            is $underlying->spot_source->tick_at($first_tick_date)->quote, 6080.73, 'Since you are asking for the exact time. We have it';
        };

        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                    epoch      => $first_tick_date->plus_time_interval('3m')->epoch,
                    quote      => 6088.73,
                    underlying => $underlying->symbol,
                })
        }
        'Add tick 3 minutes after first';

        subtest 'Request again for 2 minutes after first tick' => sub {
            my $test_time = $first_tick_date->plus_time_interval('2m');

            is $underlying->spot_source->tick_at($test_time)->quote, 6080.73, 'Get our first added tick';
            is $underlying->spot_source->tick_at($test_time->epoch, {allow_inconsistent => 1})->quote, 6080.73,
                '... and possibly inconsistent is the same';
        };
    };

    subtest 'next day tick' => sub {
        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick(

                {
                    epoch      => $first_tick_date->plus_time_interval('1d')->epoch,
                    quote      => 6077.22,
                    underlying => $underlying->symbol,
                }

                )
        }
        'Add tick at same time the next day';

        my $an_hour_before = $first_tick_date->plus_time_interval('23h')->epoch;

        is $underlying->spot_source->tick_at($an_hour_before)->quote, 6088.73, 'The lastest available tick is found from previous day';
        is $underlying->spot_source->tick_at($an_hour_before, {allow_inconsistent => 1})->quote, 6088.73, '... and possibly inconsistent is the same';
    };
};

subtest 'get_ohlc_data_for_period' => sub {
    subtest 'Invalid dates' => sub {
        my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'DJI'}]);

        throws_ok {
            $underlying->get_ohlc_data_for_period({
                start => '2012-10-20',
                end   => '2012-10-15'
            });
        }
        qr/\[get_ohlc_data_for_period\] start_date > end_date/, 'Exceptions Exceptions';
    };

    subtest 'no data' => sub {
        my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'DJI'}]);
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
        my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'DJI'}]);
        my $ohlc = $underlying->get_high_low_for_period({
            start => '2012-10-22',
            end   => '2012-10-25'
        });

        is $ohlc->{high},  13_368.55, 'Correct High';
        is $ohlc->{low},   13_063.63, 'Correct Low';
        is $ohlc->{close}, 13_077.34, 'Correct Close';
    };

    my $tick_date = Date::Utility->new('2012-10-23 14:35:00');
    my $tick      = {
        epoch      => $tick_date->epoch,
        quote      => 13_220.73,
        underlying => 'DJI'
    };

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick($tick);

    subtest 'high, low calculation from ticks' => sub {
        my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'DJI'}]);
        my $ohlc = $underlying->get_high_low_for_period({
            start => '2012-10-22',
            end   => '2012-10-23 22:00:00'
        });

        is $ohlc->{high},  13_368.55, 'Correct High';
        is $ohlc->{low},   13_220.73, 'Correct Low';
        is $ohlc->{close}, 13_220.73, 'Correct Close';
    };
};

sub check_new_ok {
    my $module  = shift;
    my $ul_args = shift;

    return create_underlying($ul_args->[0]);

}

done_testing;
