#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::FailWarnings;

use Date::Utility;
use BOM::Market::RedisTickAccessor;
use BOM::MarketData qw(create_underlying);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

my $underlying = create_underlying('R_100');
my $symbol     = $underlying->symbol;
my $now        = time;

subtest 'tick_at' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(map { [100 + $_ / 100, $now + $_, $symbol] } (1, 3, 5, 7, 10));
    my $accessor = BOM::Market::RedisTickAccessor->new(underlying => $underlying);
    ok !$accessor->tick_at($now), 'no previous tick, tick_at returns undef';
    ok !$accessor->tick_at($now, {allow_inconsistent => 1}), 'no previous tick, tick_at({allow_inconsistent => 1}) returns undef';
    is $accessor->tick_at($now + 1)->quote,  '100.01', "quote is 100.01 at $now + 1";
    is $accessor->tick_at($now + 2)->quote,  '100.01', "quote is 100.01 at $now + 2";
    is $accessor->tick_at($now + 10)->quote, '100.1',  "quote is 100.1 at $now + 10";
    ok !$accessor->tick_at($now + 11), 'no next tick, tick_at returns undef';
    is $accessor->tick_at($now + 11, {allow_inconsistent => 1})->quote, '100.1', 'no next tick, tick_at({allow_inconsistent => 1}) returns 100.1';
};

subtest 'spot_tick' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(map { [100 + $_ / 100, $now + $_, $symbol] } (10));
    my $accessor = BOM::Market::RedisTickAccessor->new(underlying => $underlying);
    ok !$accessor->spot_tick(), 'no previous tick, spot_tick returns undef';
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(map { [100 + $_ / 100, $now - $_, $symbol] } (11));
    is $accessor->spot_tick($now)->quote, 100.11, 'spot tick at 100.11';
};

subtest 'next_tick_after' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(map { [100 + $_ / 100, $now + $_, $symbol] } (1, 5));
    my $accessor = BOM::Market::RedisTickAccessor->new(underlying => $underlying);
    ok !$accessor->next_tick_after($now + 5), 'undef if there is no next tick';
    is $accessor->next_tick_after($now)->quote, 100.01, 'next tick is 100.01';
    is $accessor->next_tick_after($now + 1)->quote, 100.05, 'next tick is 100.05';
};

subtest 'ticks_in_between_end_limit' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(map { [100 + $_ / 100, $now + $_, $symbol] } (1 .. 5));
    my $accessor = BOM::Market::RedisTickAccessor->new(underlying => $underlying);
    throws_ok { $accessor->ticks_in_between_end_limit() } qr/end_time is required/, 'throws exception if end_time is not provided';
    throws_ok { $accessor->ticks_in_between_end_limit({end_time => $now}) } qr/limit is required/, 'throws exception if limit is not provided';
    my $ticks = $accessor->ticks_in_between_end_limit({
        end_time => $now,
        limit    => 1
    });
    ok !@$ticks, "no ticks at $now";
    $ticks = $accessor->ticks_in_between_end_limit({
        end_time => $now + 2,
        limit    => 5
    });
    is scalar @$ticks, 2, 'got two ticks if we only have two';
    is $ticks->[0]->epoch, $now + 2, "first tick epoch $now + 2";
    is $ticks->[0]->quote, 100.02, "first tick quote 100.02";
    is $ticks->[1]->epoch, $now + 1, "second tick epoch $now + 1";
    is $ticks->[1]->quote, 100.01, "second tick quote 100.01";
    is_deeply(
        $ticks,
        $accessor->underlying->ticks_in_between_end_limit({
                end_time => $now + 2,
                limit    => 5
            }));
    $ticks = $accessor->ticks_in_between_end_limit({
        end_time => $now + 5,
        limit    => 4
    });
    is_deeply(
        $ticks,
        $accessor->underlying->ticks_in_between_end_limit({
                end_time => $now + 5,
                limit    => 4
            }));
};

subtest 'ticks_in_between_start_limit' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(map { [100 + $_ / 100, $now + $_, $symbol] } (1 .. 5));
    my $accessor = BOM::Market::RedisTickAccessor->new(underlying => $underlying);
    throws_ok { $accessor->ticks_in_between_start_limit() } qr/start_time is required/, 'throws exception if start_time is not provided';
    throws_ok { $accessor->ticks_in_between_start_limit({start_time => $now}) } qr/limit is required/, 'throws exception if limit is not provided';
    my $ticks = $accessor->ticks_in_between_start_limit({
        start_time => $now + 6,
        limit      => 1
    });
    ok !@$ticks, "no ticks at $now + 6";
    $ticks = $accessor->ticks_in_between_start_limit({
        start_time => $now + 4,
        limit      => 5
    });
    is scalar @$ticks, 2, 'got two ticks if we only have two';
    is $ticks->[0]->epoch, $now + 4, "first tick epoch $now + 4";
    is $ticks->[0]->quote, 100.04, "first tick quote 100.04";
    is $ticks->[1]->epoch, $now + 5, "second tick epoch $now + 5";
    is $ticks->[1]->quote, 100.05, "second tick quote 100.05";
    is_deeply(
        $ticks,
        $accessor->underlying->ticks_in_between_start_limit({
                start_time => $now + 4,
                limit      => 5
            }));
    $ticks = $accessor->ticks_in_between_start_limit({
        start_time => $now + 2,
        limit      => 4
    });
    is_deeply(
        $ticks,
        $accessor->underlying->ticks_in_between_start_limit({
                start_time => $now + 2,
                limit      => 4
            }));
};

subtest 'ticks_in_between_start_end' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(map { [100 + $_ / 100, $now + $_, $symbol] } (1 .. 5));
    my $accessor = BOM::Market::RedisTickAccessor->new(underlying => $underlying);
    throws_ok { $accessor->ticks_in_between_start_end() } qr/start_time is required/, 'throws exception if start_time is not provided';
    throws_ok { $accessor->ticks_in_between_start_end({start_time => $now}) } qr/end_time is required/,
        'throws exception if end_time is not provided';
    throws_ok { $accessor->ticks_in_between_start_end({start_time => $now, end_time => $now - 1}) } qr/end_time is before start_time/,
        'throws exception if end_time is before start_time';
    my $ticks = $accessor->ticks_in_between_start_end({
        start_time => $now + 6,
        end_time   => $now + 7,
    });
    ok !@$ticks, "no ticks at $now + 6 to $now + 7";
    $ticks = $accessor->ticks_in_between_start_end({
        start_time => $now + 3,
        end_time   => $now + 6,
    });
    is scalar @$ticks, 3, 'got 3 ticks';
    is $ticks->[2]->epoch, $now + 3, "first tick epoch $now + 3";
    is $ticks->[2]->quote, 100.03, "first tick quote 100.03";
    is $ticks->[1]->epoch, $now + 4, "second tick epoch $now + 4";
    is $ticks->[1]->quote, 100.04, "second tick quote 100.04";
    is $ticks->[0]->epoch, $now + 5, "second tick epoch $now + 5";
    is $ticks->[0]->quote, 100.05, "second tick quote 100.05";
    is_deeply $ticks,
        $accessor->underlying->ticks_in_between_start_end({
            start_time => $now + 3,
            end_time   => $now + 6,
        });
};

done_testing();
