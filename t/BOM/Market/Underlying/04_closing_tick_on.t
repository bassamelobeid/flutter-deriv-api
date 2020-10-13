use Test::Most;
use Test::MockTime qw( :all );
use Test::FailWarnings;
use Test::MockObject;
use Test::MockModule;
use File::Spec;
use Date::Parse;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;
use BOM::MarketData qw(create_underlying);

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
        my $underlying = check_new_ok('Quant::Framework::Underlying' => [{symbol => 'frxUSDJPY'}]);
        is $underlying->closing_tick_on('2012-05-30')->close, 90.1, 'close for 2012-05-30';
        is $underlying->closing_tick_on('2012-05-31')->close, 91.1, 'close for 2012-05-31';
        is $underlying->closing_tick_on('2012-06-01'), undef, 'ohlc for 2012-06-01 not aggregated yet';
        is $underlying->closing_tick_on('2012-06-02'), undef, 'no tick for 2012-06-01';
    };
};

sub check_new_ok {
    my $module  = shift;
    my $ul_args = shift;

    return create_underlying($ul_args->[0]);
}
done_testing;
