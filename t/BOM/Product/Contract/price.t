#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Product::ContractFactory qw(produce_contract);

use Test::More tests => 5;
use Test::Exception;
use Test::NoWarnings;
use Date::Utility;
use BOM::Test::Data::Utility::FeedTestDatabase;
use Cache::RedisDB;

my $start_time = Date::Utility->new->minus_time_interval('1h');

my %contract_params = (
    bet_type   => 'PUT',
    underlying => 'R_100',
    duration   => '1m',
    barrier    => 'S0P',
    currency   => 'USD',
    payout     => 10,
);

my $c = produce_contract({
    %contract_params,
    date_start   => $start_time->epoch - 1,
    date_pricing => $start_time->epoch + 61,
});

create_ticks(
    [100, $start_time->epoch - 1,  'R_100'],
    [101, $start_time->epoch + 1,  'R_100'],
    [102, $start_time->epoch + 5,  'R_100'],
    [102, $start_time->epoch + 59, 'R_100']);

is $c->bid_price, 0, 'bid price for loss expired contract';

$c = produce_contract({
    %contract_params,
    date_start   => $start_time->epoch - 1,
    date_pricing => $start_time->epoch + 61,
});

create_ticks(
    [100, $start_time->epoch - 1,  'R_100'],
    [101, $start_time->epoch + 1,  'R_100'],
    [102, $start_time->epoch + 5,  'R_100'],
    [99,  $start_time->epoch + 59, 'R_100']);

is $c->bid_price, 10, 'bid price for win expired contract';

$c = produce_contract({
    %contract_params,
    date_start   => $start_time->epoch - 1,
    date_pricing => $start_time->epoch - 1,
});

create_ticks([100, $start_time->epoch - 1, 'R_100']);

is $c->ask_price, 5.15, 'ask price of a contract at beginning';

$c = produce_contract({
    %contract_params,
    date_start   => $start_time->epoch - 1,
    date_pricing => $start_time->epoch + 10,
});

create_ticks([100, $start_time->epoch - 1, 'R_100'], [101, $start_time->epoch + 1, 'R_100'], [80, $start_time->epoch + 5, 'R_100'],);

is $c->bid_price, 9.75, 'bid price for not expired contract';

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
