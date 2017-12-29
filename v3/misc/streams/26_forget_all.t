use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::MockTime qw/:all/;
use Encode;
use JSON::MaybeXS;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use File::Temp;
use Date::Utility;
use await;

use BOM::Platform::RedisReplicated;
use BOM::Test::Data::Utility::FeedTestDatabase;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

initialize_realtime_ticks_db();

{
    local $SIG{__WARN__} = sub { };

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_50',
        epoch      => Date::Utility->new->epoch,
        quote      => 100
    });

    my $ohlc_sample =
        '60:7807.4957,7811.9598,7807.1055,7807.1055;120:7807.0929,7811.9598,7806.6856,7807.1055;180:7793.6775,7811.9598,7793.5814,7807.1055;300:7807.0929,7811.9598,7806.6856,7807.1055;600:7807.0929,7811.9598,7806.6856,7807.1055;900:7789.5519,7811.9598,7784.1465,7807.1055;1800:7789.5519,7811.9598,7784.1465,7807.1055;3600:7723.5128,7811.9598,7718.4277,7807.1055;7200:7723.5128,7811.9598,7718.4277,7807.1055;14400:7743.3676,7811.9598,7672.4463,7807.1055;28800:7743.3676,7811.9598,7672.4463,7807.1055;86400:7743.3676,7811.9598,7672.4463,7807.1055;';

    sub _create_tick {    #creates R_50 tick in redis channel FEED::R_50
        my ($i, $symbol) = @_;
        $i ||= 700;
        my $payload = {
            symbol => $symbol,
            epoch  => int(time),
            spot   => $i,
            ask    => $i - 1,
            bid    => $i + 1,
            ohlc   => $ohlc_sample,
        };
        BOM::Platform::RedisReplicated::redis_write->publish("FEED::$symbol", Encode::encode_utf8(JSON::MaybeXS->new->encode($payload)));
    }

    my $t = build_wsapi_test();

    sub _check_ticks {
        my $type = shift;
        my $msg  = shift;

        # both these subscribtion should work as req_id is different
        my $pid = fork;
        die "Failed fork for testing 'ticks' WS API call: $@" unless defined $pid;
        unless ($pid) {
            # disable end test of Test::Warnings in child process
            Test::Warnings->import(':no_end_test');
            do { sleep 1; _create_tick(700, 'R_50'); }
                for 0 .. 1;
            exit;
        }
        $type eq 'ticks' ? $t->await::tick($msg) : $t->await::ohlc($msg);
        $msg->{req_id} = 1;
        $type eq 'ticks' ? $t->await::tick($msg) : $t->await::ohlc($msg);

        my $res = $t->await::forget_all({forget_all => $type});
        ok $res->{forget_all}, "Manage to forget_all: ticks" or diag explain $res;
        is scalar(@{$res->{forget_all}}), 2, "Forget the relevant tick channel";
    }

    _check_ticks('ticks', {ticks => 'R_50'});
    _check_ticks(
        'candles',
        {
            ticks_history => 'R_50',
            end           => "latest",
            count         => 10,
            style         => "candles",
            subscribe     => 1
        });

    $t->finish_ok;
}
done_testing();
