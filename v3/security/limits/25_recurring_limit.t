#!perl

use strict;
use warnings;
use Test::More;
use Data::Dumper;
use Encode;
use JSON::MaybeXS;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Config::RedisReplicated;
use await;
my $t    = build_wsapi_test();
my $json = JSON::MaybeXS->new;

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_50',
    epoch      => int(time),
    quote      => 100
});

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
    BOM::Config::RedisReplicated::redis_write()->publish("DISTRIBUTOR_FEED::$symbol", Encode::encode_utf8($json->encode($payload)));
}
my $pid = fork;
die "Failed fork for testing 'ticks' WS API call: $@" unless defined $pid;
unless ($pid) {
    # disable end test of Test::Warnings in child process
    Test::Warnings->import(':no_end_test');
    do { sleep 1; _create_tick(700, 'R_50'); }
        for 0 .. 1;

    exit;
}

$t->await::tick({
    ticks  => 'R_50',
    req_id => 1
});
my $res = $t->await::tick({
    ticks  => 'R_50',
    req_id => 1
});
is $res->{error}->{code}, 'AlreadySubscribed';

done_testing();
