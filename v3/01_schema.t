use Test::Most;
use Test::Mojo;
use JSON::Schema;
use JSON;
use File::Slurp;
use File::Basename;
use Data::Dumper;
use Finance::Asset;
# we need this import here so the market-data db will be fresh for the test
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

use Date::Utility;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Test::Data::Utility::FeedTestDatabase;
use BOM::Test::Helper qw/launch_redis/;
use BOM::Platform::RedisReplicated;
use BOM::Test::Helper qw/build_wsapi_test/;

initialize_realtime_ticks_db();

# R_50 is used in example.json for ticks and ticks_history Websocket API calls
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_50',
    epoch      => Date::Utility->new->epoch,
    quote      => 100
});

my $ohlc_sample =
    '60:7807.4957,7811.9598,7807.1055,7807.1055;120:7807.0929,7811.9598,7806.6856,7807.1055;180:7793.6775,7811.9598,7793.5814,7807.1055;300:7807.0929,7811.9598,7806.6856,7807.1055;600:7807.0929,7811.9598,7806.6856,7807.1055;900:7789.5519,7811.9598,7784.1465,7807.1055;1800:7789.5519,7811.9598,7784.1465,7807.1055;3600:7723.5128,7811.9598,7718.4277,7807.1055;7200:7723.5128,7811.9598,7718.4277,7807.1055;14400:7743.3676,7811.9598,7672.4463,7807.1055;28800:7743.3676,7811.9598,7672.4463,7807.1055;86400:7743.3676,7811.9598,7672.4463,7807.1055;';

sub _create_tick {    #creates R_50 tick in redis channel FEED::R_50
    my $i       = shift || 700;
    my $symbol  = 'R_50';
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

my ($t, $test_name, $response) = (build_wsapi_test());

my $v = 'config/v3';
explain "Testing version: $v";
foreach my $f (grep { -d } glob "$v/*") {
    $test_name = File::Basename::basename($f);
    explain $f;
    my $send = JSON::from_json(File::Slurp::read_file("$f/example.json"));
    $t->send_ok({json => $send}, "send request for $test_name");
    if ($f eq "$v/ticks") {
        # upcoming $t->message_ok for 'ticks' WS API call subscribes to FEED::R_50 channel
        # all messages posted before this call and after it bails out on timeout are ignored
        # so fork here allows to populate channel while subscription is on
        my $pid = fork;
        die "Failed fork for testing 'ticks' WS API call: $@" unless defined $pid;
        unless ($pid) {
            # disable end test of Test::Warnings in child process
            Test::Warnings->import(':no_end_test');
            for (1 .. 10) {
                _create_tick(700 + $_);
                sleep 1;
            }
            exit;
        }
    }
    $t->message_ok("$test_name got a response");
    my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/receive.json")));
    my $result    = $validator->validate(Mojo::JSON::decode_json $t->message->[1]);
    ok $result, "$f response is valid";
    if (not $result) { print " - $_\n" foreach $result->errors; print Data::Dumper::Dumper(Mojo::JSON::decode_json $t->message->[1]) }
}

done_testing;
