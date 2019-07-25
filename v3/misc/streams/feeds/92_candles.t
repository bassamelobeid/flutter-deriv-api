use strict;
use warnings;
use Test::More;
use Test::MockTime qw/:all/;
use JSON::MaybeUTF8 qw/encode_json_utf8 decode_json_utf8/;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Config::RedisReplicated;
use File::Temp;
use Date::Utility;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

my $json = JSON::MaybeXS->new;

for my $symbol (qw/R_50 R_100/) {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $symbol,
            epoch      => Date::Utility->new->epoch,
            quote      => 100
        },
        0
    );
}

my $ohlc_sample =
    '60:7807.4957,7811.9598,7807.1055,7807.1055;120:7807.0929,7811.9598,7806.6856,7807.1055;180:7793.6775,7811.9598,7793.5814,7807.1055;300:7807.0929,7811.9598,7806.6856,7807.1055;600:7807.0929,7811.9598,7806.6856,7807.1055;900:7789.5519,7811.9598,7784.1465,7807.1055;1800:7789.5519,7811.9598,7784.1465,7807.1055;3600:7723.5128,7811.9598,7718.4277,7807.1055;7200:7723.5128,7811.9598,7718.4277,7807.1055;14400:7743.3676,7811.9598,7672.4463,7807.1055;28800:7743.3676,7811.9598,7672.4463,7807.1055;86400:7743.3676,7811.9598,7672.4463,7807.1055;';

sub _create_tick {    #creates R_50 tick in redis channel DISTRIBUTOR_FEED::R_50
    my ($i, $symbol) = @_;
    $i ||= 700;
    my $payload = {
        symbol => $symbol,
        epoch  => int(time),
        quote  => $i,
        ask    => $i - 1,
        bid    => $i + 1,
        ohlc   => $ohlc_sample,
    };
    BOM::Config::RedisReplicated::redis_write()->publish("DISTRIBUTOR_FEED::$symbol", encode_json_utf8($payload));
}

my $t = build_wsapi_test();

my ($res);

$res = $t->send_ok({
        json => {
            ticks_history => 'R_50',
            end           => "latest",
            count         => 10,
            style         => "candles",
            subscribe     => 1
        }})->message_ok;
$res = decode_json_utf8($res->message->[1]);

test_schema('ticks_history', $res);

is $res->{msg_type}, 'candles', 'Correct message type';
ok $res->{subscription}->{id}, 'Subscription id is ok';
is ref $res->{candles}, 'ARRAY', 'Valid datatype array ref';

my $pid = fork;
die "Failed fork for testing 'ticks' WS API call: $@" unless defined $pid;
unless ($pid) {
    # disable end test of Test::Warnings in child process
    Test::Warnings->import(':no_end_test');

    sleep 1;
    for (1 .. 2) {
        _create_tick(700 + $_, 'R_50');
        sleep 1;
    }
    exit;
}

for (my $i = 0; $i < 2; $i++) {
    $t->message_ok;
    $res = decode_json_utf8($t->message->[1]);

    ok $res->{ohlc}->{open} =~ /\d+\.\d{4,}/
        && $res->{ohlc}->{high} =~ /\d+\.\d{4,}/
        && $res->{ohlc}->{close} =~ /\d+\.\d{4,}/
        && $res->{ohlc}->{low} =~ /\d+\.\d{4,}/, 'OHLC should be pipsized';
}

$t->finish_ok;

done_testing();
