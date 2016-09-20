use strict;
use warnings;
use Cache::RedisDB;
use BOM::Platform::CurrencyConverter;
use Test::More tests => 17;
use Test::Exception;
use Scalar::Util ('looks_like_number');
use feature 'say';

$ENV{'REDIS_CACHE_SERVER'} = $ENV{'REDIS_CACHE_SERVER'} // '127.0.0.1:6379';

Cache::RedisDB->redis();

Cache::RedisDB->set('QUOTE', 'frxNGNUSD', {quote => 167.10});
Cache::RedisDB->set('QUOTE', 'frxMGNUSD', {quote => 2});

is(BOM::Platform::CurrencyConverter::in_USD(1, 'NGN'), Cache::RedisDB->get('QUOTE', 'frxNGNUSD')->{quote},     "1 USD to NGN is 167.10 NGN");
is(BOM::Platform::CurrencyConverter::in_USD(3, 'NGN'), Cache::RedisDB->get('QUOTE', 'frxNGNUSD')->{quote} * 3, "3 USD to NGN is 501.30 NGN");
dies_ok { BOM::Platform::CurrencyConverter::in_USD('NGN', '') } 'No valid amount or source currency was provided - non-numeric amount';
dies_ok { BOM::Platform::CurrencyConverter::in_USD('NGN', undef) } 'No valid amount or source currency was provided - non-numeric amount';
dies_ok { BOM::Platform::CurrencyConverter::in_USD(undef, '') } 'No valid amount or source currency was provided - undefined amount';
dies_ok { BOM::Platform::CurrencyConverter::in_USD() } 'No valid amount or source currency was provided - no amount or currency';
dies_ok { BOM::Platform::CurrencyConverter::in_USD('NGN') } 'No valid amount or source currency was provided - non-numeric amount again';
dies_ok { BOM::Platform::CurrencyConverter::in_USD(12) } 'No valid amount or source currency was provided - no currency provided';
dies_ok { BOM::Platform::CurrencyConverter::in_USD(12, undef) } 'No valid amount or source currency was provided - undefined currency';
dies_ok { BOM::Platform::CurrencyConverter::in_USD(12, '') } 'No valid amount or source currency was provided - empty currency provided';

is(BOM::Platform::CurrencyConverter::in_USD(0, 'NGN'), 0, "A price of \"zero\" was detected");
is(BOM::Platform::CurrencyConverter::in_USD(1, 'USD'), 1, "What is the point converting from USD to USD");

dies_ok { BOM::Platform::CurrencyConverter::in_USD(12, 'UMPA') } "A non existent currency was probably provided";

is(BOM::Platform::CurrencyConverter::amount_from_to_currency(1,  'NGN', 'USD'), 167.1, 'NGN => USD');
is(BOM::Platform::CurrencyConverter::amount_from_to_currency(2,  'NGN', 'MGN'), 167.1, 'NGN => MGN');
is(BOM::Platform::CurrencyConverter::amount_from_to_currency(2,  'USD', 'MGN'), 1,     'MGN => USD');
is(BOM::Platform::CurrencyConverter::amount_from_to_currency(10, 'USD', 'USD'), 10,    'Calling on "in_USD" from dollar to dollar');

Cache::RedisDB->del('QUOTE', 'frxNGNUSD', {quote => 167.10});
Cache::RedisDB->del('QUOTE', 'frxMGNUSD', {quote => 2});

done_testing();

