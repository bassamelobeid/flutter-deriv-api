#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 4;

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

create_ticks(
    [100, $start_time->epoch,                  'R_100'],
    [101, $start_time->epoch + 1,              'R_100'],
    [102, $start_time->epoch + 5,              'R_100'],
    [102, $start_time->epoch + $duration * 60, 'R_100']);

is $c->bid_price, 0, 'bid price for loss expired contract';

$c = produce_contract({
    %contract_params,
    date_start   => $start_time->epoch,
    date_pricing => $start_time->epoch + 61,
});

create_ticks(
    [100, $start_time->epoch,                  'R_100'],
    [101, $start_time->epoch + 1,              'R_100'],
    [102, $start_time->epoch + 5,              'R_100'],
    [99,  $start_time->epoch + $duration * 60, 'R_100']);

is $c->bid_price, 10, 'bid price for win expired contract';

$c = produce_contract({
    %contract_params,
    date_start   => $start_time->epoch,
    date_pricing => $start_time->epoch,
});

create_ticks([100, $start_time->epoch, 'R_100']);

ok $c->ask_price, 'ask price of a contract at beginning';

$c = produce_contract({
    %contract_params,
    date_start   => $start_time->epoch,
    date_pricing => $start_time->epoch + 10,
});

create_ticks([100, $start_time->epoch, 'R_100'], [101, $start_time->epoch + 1, 'R_100'], [80, $start_time->epoch + 5, 'R_100']);

ok $c->bid_price, 'bid price for not expired contract';

sub create_ticks {
    my @ticks = @_;

    Cache::RedisDB->flushall;
    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;

    for my $tick (@ticks) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            quote      => $tick->[0],
            epoch      => $tick->[1],
            underlying => $tick->[2],
        });
    }
    Time::HiRes::sleep(0.1);

    return;
}
