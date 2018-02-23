use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal;
use Test::MockTime qw(:all);
use File::Temp qw(tempfile);
use YAML::XS qw(LoadFile DumpFile);

use BOM::RPC::v3::Utility;

(undef, my $rate_file) = tempfile();
my $limits = {
    virtual_buy_transaction => {
        '1m' => 1000000,
        '1h' => 2000000,
    },
    virtual_sell_transaction => {
        '1m' => 1000000,
        '1h' => 2000000,
    },
    virtual_batch_sell => {
        '1m' => 1000000,
        '1h' => 2000000,
    },
    websocket_call => {
        '1m' => 1000000,
        '1h' => 2000000,
    },
    websocket_call_expensive => {
        '1m' => 1000000,
        '1h' => 2000000,
    },
    websocket_call_pricing => {
        '1m' => 1000000,
        '1h' => 2000000,
    },
    websocket_call_restricted => {
        '1m' => 1000000,
        '1h' => 2000000,
    },
    websocket_real_pricing => {
        '1m' => 1000000,
        '1h' => 2000000,
    },
};
DumpFile($rate_file, $limits);

$ENV{BOM_TEST_RATE_LIMITATIONS} = $rate_file;

my $expected = {
    applies_to => ignore(),
    minutely   => $limits->{websocket_call_pricing}{'1m'},
    hourly     => $limits->{websocket_call_pricing}{'1h'},
};
cmp_deeply(BOM::RPC::v3::Utility::site_limits->{max_requests_pricing}, $expected, 'rate limits match');
++$limits->{websocket_call_pricing}{'1m'};
DumpFile($rate_file, $limits);
cmp_deeply(BOM::RPC::v3::Utility::site_limits->{max_requests_pricing}, $expected, 'rate limits still match old values');
set_relative_time(1 + BOM::RPC::v3::Utility->RATES_FILE_CACHE_TIME);

$expected->{minutely} = $limits->{websocket_call_pricing}{'1m'};
cmp_deeply(BOM::RPC::v3::Utility::site_limits->{max_requests_pricing}, $expected, 'rate limits have picked up new values after timeout');

done_testing;

