use strict;
use warnings;
use Test::More;
use Test::MockTime qw/:all/;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Platform::RedisReplicated;
use File::Temp;
use Date::Utility;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

for my $symbol (qw/R_50 R_100/) {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $symbol,
        epoch      => Date::Utility->new->epoch,
        quote      => 100
    });
}

sub _create_tick {    #creates R_50 tick in redis channel FEED::R_50
    my ($i, $symbol) = @_;
    $i      ||= 700;
    $symbol ||= 'R_50';
    my $ohlc_sample =
        '60:7807.4957,7811.9598,7807.1055,7807.1055;120:7807.0929,7811.9598,7806.6856,7807.1055;180:7793.6775,7811.9598,7793.5814,7807.1055;300:7807.0929,7811.9598,7806.6856,7807.1055;600:7807.0929,7811.9598,7806.6856,7807.1055;900:7789.5519,7811.9598,7784.1465,7807.1055;1800:7789.5519,7811.9598,7784.1465,7807.1055;3600:7723.5128,7811.9598,7718.4277,7807.1055;7200:7723.5128,7811.9598,7718.4277,7807.1055;14400:7743.3676,7811.9598,7672.4463,7807.1055;28800:7743.3676,7811.9598,7672.4463,7807.1055;86400:7743.3676,7811.9598,7672.4463,7807.1055;';

    my $payload = {
        symbol => $symbol,
        epoch  => int(time),
        spot   => $i,
        ask    => $i - 1,
        bid    => $i + 1,
        ohlc   => $ohlc_sample,
    };
    BOM::Platform::RedisReplicated::redis_write->publish("FEED::$symbol", encode_json($payload));
}

my $t = build_wsapi_test();

my ($res, $ticks);

my $pid = fork;
die "Failed fork for testing 'ticks' WS API call: $@" unless defined $pid;
unless ($pid) {
    # disable end test of Test::Warnings in child process
    Test::Warnings->import(':no_end_test');

    sleep 1;
    for (1 .. 3) {
        _create_tick(700 + $_, 'R_50');
        _create_tick(700 + $_, 'R_100');
        sleep 1;
    }
    exit;
}

subtest 'ticks' => sub {
    $t->send_ok({json => {ticks => ['R_50', 'R_100']}});
    $t->send_ok({json => {ticks => 'R_50'}})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{error}->{code}, 'AlreadySubscribed', 'Should return already subscribed error';
    is $res->{error}->{message}, 'You are already subscribed to R_50', 'Should return already subscribed error';

    $t->send_ok({json => {ticks => 'R_5012312312'}})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{error}->{code}, 'InvalidSymbol', 'Should return invalid symbol error';
};

subtest 'ticks_forget_one_sub' => sub {
        my $res = $t->await::forget_all({forget_all => 'ticks'});
        my $req1 = {
            "ticks_history" => "R_50",
            "granularity"   => 60,
            "style"         =>"candles",
            "count"         =>1,
            "end"           => "latest",
            "subscribe"     => 1,
        };
        my $req2 = {
            "ticks_history" => "R_50",
            "granularity"   => 0,
            "style"         => "ticks",
            "count"         => 1,
            "end"           => "latest",
            "subscribe"     => 1,
        };

        $res = $t->await::candles($req1);
        $res = $t->await::ohlc;
        cmp_ok $res->{msg_type}, 'eq', 'ohlc', "Recived ohlc response ok";

        my $id1 = $res->{ohlc}{id};
        ok $id1, "Subscription id ok";

        $res = $t->await::history($req2);
        cmp_ok $res->{msg_type}, 'eq', 'history', "Recived tick history response ok";

        $res = $t->await::forget({forget => $id1});
        cmp_ok $res->{forget}, '==', 1, "One subscription deleted ok";

        $res = $t->await::tick;
        cmp_ok $res->{msg_type}, 'eq', 'tick', "Second supscription is ok";

};

$t->finish_ok;

done_testing();
