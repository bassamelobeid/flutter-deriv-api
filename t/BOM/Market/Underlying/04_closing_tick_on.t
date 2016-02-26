use Test::Most;
use Test::MockTime qw( :all );
use Test::FailWarnings;
use Test::MockObject;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use Date::Parse;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

use Date::Utility;
use BOM::Market::Underlying;

subtest 'closing_tick_on - official OHLC' => sub {
    subtest 'prepare unofficial ohlc - DJI' => sub {
        my @daily = ({
                date  => '2012-05-30 00:00:00',
                quote => 12388.56,
                bid   => 12388.56,
                ask   => 12388.56
            },
            {
                date  => '2012-05-31 09:20:20',
                quote => 12117.48,
                bid   => 12117.48,
                ask   => 12117.48
            },
            {
                date  => '2012-06-01 00:20:20',
                quote => 12119.48,
                bid   => 12119.48,
                ask   => 12119.48
            },
        );

        foreach my $ohlc (@daily) {
            lives_ok {
                BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                    epoch      => Date::Parse::str2time($ohlc->{date}),
                    quote      => $ohlc->{quote},
                    bid        => $ohlc->{bid},
                    ask        => $ohlc->{ask},
                    underlying => 'DJI'
                });
            }
            'for ohlc daily - ' . $ohlc->{date};
        }
    };

    subtest 'prepare official ohlc - DJI' => sub {
        my @daily = ({
                date  => '2012-05-30',
                open  => 12391.56,
                high  => 12391.63,
                low   => 12107.48,
                close => 12118.57
            },
            {
                date  => '2012-05-31',
                open  => 12119.85,
                high  => 12143.69,
                low   => 12035.09,
                close => 12101.46
            },
        );
        for my $ohlc (@daily) {
            my $date = Date::Utility->new($ohlc->{date});

            lives_ok {
                BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
                    epoch      => $date->epoch,
                    open       => $ohlc->{open},
                    high       => $ohlc->{high},
                    low        => $ohlc->{low},
                    close      => $ohlc->{close},
                    official   => 1,
                    underlying => 'DJI'
                });
            }
            'Daily Official ' . $date->date_yyyymmdd;
        }
    };

    subtest 'closing_tick_on - should use official OHLC for DJI' => sub {
        my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'DJI'}]);
        is $underlying->closing_tick_on('2012-05-30')->close, 12118.57, 'close for 2012-05-30';
        is $underlying->closing_tick_on('2012-05-31')->close, 12101.46, 'close for 2012-05-31';
        is $underlying->closing_tick_on('2012-06-01'), undef, 'no official close yet for 2012-06-01';
        is $underlying->closing_tick_on('2012-06-02'), undef, 'is weekend - no official close as market not open';
    };
};

subtest 'closing_tick_on - unofficial OHLC' => sub {
    subtest 'prepare unofficial ohlc - frxUSDJPY' => sub {
        my @daily = ({
                date  => '2012-05-30 00:00:00',
                quote => 90.1,
                bid   => 90.1,
                ask   => 90.1
            },
            {
                date  => '2012-05-31 09:20:20',
                quote => 91.1,
                bid   => 91.1,
                ask   => 91.1
            },
            {
                date  => '2012-06-01 00:20:20',
                quote => 92.1,
                bid   => 92.1,
                ask   => 92.1
            },
        );

        foreach my $ohlc (@daily) {
            lives_ok {
                BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                    epoch      => Date::Parse::str2time($ohlc->{date}),
                    quote      => $ohlc->{quote},
                    bid        => $ohlc->{bid},
                    ask        => $ohlc->{ask},
                    underlying => 'frxUSDJPY'
                });
            }
            'for ohlc daily - ' . $ohlc->{date};
        }
    };

    subtest 'closing_tick_on - should use unofficial OHLC for frxUSDJPY' => sub {
        my $underlying = new_ok('BOM::Market::Underlying' => [{symbol => 'frxUSDJPY'}]);
        is $underlying->closing_tick_on('2012-05-30')->close, 90.1, 'close for 2012-05-30';
        is $underlying->closing_tick_on('2012-05-31')->close, 91.1, 'close for 2012-05-31';
        is $underlying->closing_tick_on('2012-06-01'), undef, 'ohlc for 2012-06-01 not aggregated yet';
        is $underlying->closing_tick_on('2012-06-02'), undef, 'no tick for 2012-06-01';
    };
};

done_testing;
