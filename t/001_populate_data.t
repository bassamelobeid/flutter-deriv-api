use strict;
use warnings;
use Cache::RedisDB;
use Test::More;

Cache::RedisDB->set('QUOTE', 'frxDAIUSD', {quote => 1});
Cache::RedisDB->set('QUOTE', 'frxUSDDAI', {quote => 1});

is(Cache::RedisDB->get('QUOTE', 'frxDAIUSD')->{quote}, 1, "DAI to USD is set");
is(Cache::RedisDB->get('QUOTE', 'frxUSDDAI')->{quote}, 1, "USD to DAI is set");

done_testing;