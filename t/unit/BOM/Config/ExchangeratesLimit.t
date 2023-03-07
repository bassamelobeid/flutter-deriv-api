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

my $redis_exchangerates = BOM::Config::Redis::redis_exchangerates();

subtest 'return_exchangerate_limit_value_from_cache' => sub {
    my $cached_price = 198697;

    $redis_exchangerates->set("limit:USD-to-ETH:150", $cached_price);
    is get_exchangerates_limit(150, 'ETH'), $cached_price;

    $redis_exchangerates->del("limit:USD-to-ETH:150");
};

subtest 'calculation_done_right_in_absence_of_cache' => sub {
    my $amount       = 40;
    my $eth_usd_rate = 1587.02050;

    my $expected_price = 0.03;

    my $exchangerate_limit_keys = $redis_exchangerates->keys("limit:USD-to-ETH*");
    _remove_redis_keys($exchangerate_limit_keys);

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
    my $exchangerate_limit_keys = $redis_exchangerates->keys("limit:USD-to-ETH*");
    my $exchangerate_keys       = $redis_exchangerates->keys("exchange_rates::ETH*");

    _remove_redis_keys($exchangerate_limit_keys);
    _remove_redis_keys($exchangerate_keys);

    my $error = exception { get_exchangerates_limit(340, 'ETH') };
    is $error =~ /No rate available to convert ETH to USD/, 1;
};

sub _remove_redis_keys {
    my ($keys) = @_;

    for my $i (@$keys) { BOM::Config::Redis::redis_exchangerates()->del($i); }
}

done_testing;
