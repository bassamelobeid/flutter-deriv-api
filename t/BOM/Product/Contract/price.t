#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::Warnings;

use Date::Utility;
use Cache::RedisDB;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

use BOM::Product::ContractFactory qw(produce_contract);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => 'USD'});

my $start_time = Date::Utility->new;

my $duration        = 1;    # 1 minute
my %contract_params = (
    bet_type   => 'PUT',
    underlying => 'R_100',
    barrier    => 'S0P',
    payout     => 10,
    currency   => 'USD',
    duration   => "${duration}m",
);

my $c = produce_contract({
    %contract_params,
    date_start   => $start_time->epoch,
    date_pricing => $start_time->epoch + 61,
});

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
    [100, $start_time->epoch,                  'R_100'],
    [101, $start_time->epoch + 1,              'R_100'],
    [102, $start_time->epoch + 5,              'R_100'],
    [102, $start_time->epoch + $duration * 60, 'R_100']);

cmp_ok $c->bid_price, '==', 0, 'bid price for loss expired contract';

$c = produce_contract({
    %contract_params,
    date_start   => $start_time->epoch,
    date_pricing => $start_time->epoch + 61,
});

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
    [100, $start_time->epoch,                  'R_100'],
    [101, $start_time->epoch + 1,              'R_100'],
    [102, $start_time->epoch + 5,              'R_100'],
    [99,  $start_time->epoch + $duration * 60, 'R_100']);

cmp_ok $c->bid_price, '==', 10, 'bid price for win expired contract';

$c = produce_contract({
    %contract_params,
    date_start   => $start_time->epoch,
    date_pricing => $start_time->epoch,
});

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $start_time->epoch, 'R_100']);

ok $c->ask_price, 'ask price of a contract at beginning';

$c = produce_contract({
    %contract_params,
    date_start   => $start_time->epoch,
    date_pricing => $start_time->epoch + 10,
});

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
    [100, $start_time->epoch,     'R_100'],
    [101, $start_time->epoch + 1, 'R_100'],
    [80,  $start_time->epoch + 5, 'R_100']);

ok $c->bid_price, 'bid price for not expired contract';
