use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Fatal;
use Test::MockModule;
use BOM::Config::Redis;
use Format::Util::Numbers qw(roundnear);
use BOM::Config::Quants   qw(get_exchangerates_limit);
use Time::HiRes           qw(gettimeofday tv_interval);

use Test::MockModule;

my $redis_exchangerates = BOM::Config::Redis::redis_exchangerates();
my $quants_mock         = Test::MockModule->new("BOM::Config::Quants");

subtest "get_exchangerates_limit - caching" => sub {

    $quants_mock->mock(
        convert_currency => sub {
            my ($amt, $currency, $tocurrency, $seconds) = @_;
            return $amt * 2;
        });

    $quants_mock->mock(
        _round => sub {
            my ($number, $allowed_difference) = @_;
            return $number;
        });

    my $erl_cache = BOM::Config::Quants::get_exchange_rate_limit_cache_ref;
    # Make sure the cache is clear
    $erl_cache->clear;

    # Test cache return is same and cache entry present after call
    my $target_currency = "BTC";
    my $target_value    = 42;
    my $key             = "limit:USD-to-$target_currency:$target_value";
    my $val1            = BOM::Config::Quants::get_exchangerates_limit($target_value, $target_currency);
    my $val1_cache      = $erl_cache->get($key);
    ok($erl_cache->get($key), "ERL cache entry present");
    my $val2 = BOM::Config::Quants::get_exchangerates_limit($target_value, $target_currency);
    is($val1,       $val2,                 "Cached value returning same");
    is($val1_cache, $erl_cache->get($key), "Cache is unchanged, new entry wasn't built");

    # Test return is different for different value
    my $val3 = BOM::Config::Quants::get_exchangerates_limit($target_value + 1, $target_currency);
    isnt($val2, $val3, "Cached different value, different result");

    # Test cache timeout, force cache expiry, cheat, don't wait
    $erl_cache->get($key)->{time}[0] -= (BOM::Config::Quants::ERL_CACHE_EXPIRY + 1);
    my $old_cache_time = $erl_cache->get($key)->{time}[0];
    my $val4           = BOM::Config::Quants::get_exchangerates_limit($target_value, $target_currency);
    is($val2, $val4, "Cached value returning same");
    my $new_cache_time = $erl_cache->get($key)->{time}[0];
    isnt($old_cache_time, $new_cache_time, "Cache time has changed, cache was updated after timeout");

    $quants_mock->unmock_all();
};

subtest 'return_exchangerate_limit_value_from_cache' => sub {
    my $cached_price = 198697;

    my $erl_cache = BOM::Config::Quants::get_exchange_rate_limit_cache_ref;
    $erl_cache->clear;
    $erl_cache->set(
        'limit:USD-to-ETH:150' => {
            time => [gettimeofday],
            erl  => $cached_price
        });

    is get_exchangerates_limit(150, 'ETH'), $cached_price;
};

subtest 'calculation_done_right_in_absence_of_cache' => sub {
    my $amount       = 40;
    my $eth_usd_rate = 1587.02050;

    my $expected_price = 0.03;

    my $erl_cache = BOM::Config::Quants::get_exchange_rate_limit_cache_ref;
    $erl_cache->clear;

    $redis_exchangerates->hmset(
        'exchange_rates::ETH_USD',
        quote => $eth_usd_rate,
        epoch => time
    );

    is $expected_price, get_exchangerates_limit($amount, 'ETH');
};

subtest 'do_not_process_undef_values' => sub {
    is get_exchangerates_limit(1000), undef;
    is get_exchangerates_limit(undef, 'GBP'), undef;
    is get_exchangerates_limit(40,    undef), undef;
};

subtest 'throw_exception_in_absence_of_exchange_rate_in_redis' => sub {
    my $exchangerate_keys = $redis_exchangerates->keys("exchange_rates::ETH*");

    _remove_redis_keys($exchangerate_keys);
    my $erl_cache = BOM::Config::Quants::get_exchange_rate_limit_cache_ref;
    $erl_cache->clear;

    my $error = exception { get_exchangerates_limit(340, 'ETH') };
    is $error =~ /No rate available to convert ETH to USD/, 1;
};

sub _remove_redis_keys {
    my ($keys) = @_;

    for my $i (@$keys) { BOM::Config::Redis::redis_exchangerates()->del($i); }
}

done_testing;
