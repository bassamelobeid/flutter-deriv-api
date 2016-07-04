use strict;
use warnings;
use Test::More;
use Test::MockTime qw/:all/;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use BOM::System::RedisReplicated;
use BOM::Populator::InsertTicks;
use BOM::Populator::TickFile;
use File::Temp;
use Date::Utility;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_50',
    epoch      => Date::Utility->new->epoch,
    quote      => 100
});

sub _create_tick {    #creates R_50 tick in redis channel FEED::R_50
    my $i = shift || 700;
    BOM::System::RedisReplicated::redis_write->publish('FEED::R_50',
              'R_50;'
            . Date::Utility->new->epoch . ';'
            . $i
            . ';60:7807.4957,7811.9598,7807.1055,7807.1055;120:7807.0929,7811.9598,7806.6856,7807.1055;180:7793.6775,7811.9598,7793.5814,7807.1055;300:7807.0929,7811.9598,7806.6856,7807.1055;600:7807.0929,7811.9598,7806.6856,7807.1055;900:7789.5519,7811.9598,7784.1465,7807.1055;1800:7789.5519,7811.9598,7784.1465,7807.1055;3600:7723.5128,7811.9598,7718.4277,7807.1055;7200:7723.5128,7811.9598,7718.4277,7807.1055;14400:7743.3676,7811.9598,7672.4463,7807.1055;28800:7743.3676,7811.9598,7672.4463,7807.1055;86400:7743.3676,7811.9598,7672.4463,7807.1055;'
    );
}

my $t = build_mojo_test();

$t->send_ok({json => {ticks => 'R_50'}});

my $pid = fork;
die "Failed fork for testing 'ticks' WS API call: $@" unless defined $pid;
unless ($pid) {
    for (1 .. 5) {
        _create_tick(700 + $_);
        sleep 1;
    }
    exit;
}

my $res;

$t->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{tick}->{quote} =~ /\d+\.\d{4,}/, 'Tick should be pipsized value';

$t->send_ok({json => {ticks => 'R_50'}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'AlreadySubscribed', 'Should return already subscribed error';
is $res->{error}->{message}, 'You are already subscribed to R_50', 'Should return already subscribed error';

$t->send_ok({json => {ticks => 'R_5012312312'}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'InvalidSymbol', 'Should return invalid symbol error';

$t->finish_ok;

done_testing();
