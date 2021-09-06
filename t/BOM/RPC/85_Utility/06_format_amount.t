use strict;
use warnings;

use Test::Most;
use Format::Util::Numbers qw/formatnumber/;

subtest 'check amount precision' => sub {
    is formatnumber('amount', 'USD', 10),               '10.00',       'USD 10 -> 10.00';
    is formatnumber('amount', 'USD', 10.000001),        '10.00',       'USD 10.000001 -> 10.00';
    is formatnumber('amount', 'EUR', 10.000001),        '10.00',       'EUR 10.000001 -> 10.00';
    is formatnumber('amount', 'JPY', 10.000001),        '10.00',       'JPY 10.000001 -> 10.00';
    is formatnumber('amount', 'BTC', 10),               '10.00000000', 'BTC 10 -> 10.00000000';
    is formatnumber('amount', 'BTC', 10.000001),        '10.00000100', 'BTC 10.000001 -> 10.00000100';
    is formatnumber('amount', 'BTC', 10.0000000000001), '10.00000000', 'BTC 10.0000000000001 -> 10.00000000';
    is formatnumber('amount', 'ETH', 10),               '10.00000000', 'ETH 10 -> 10.00000000';
    is formatnumber('amount', 'ETH', 10.000001),        '10.00000100', 'ETH 10.000001 -> 10.00000100';
    is formatnumber('amount', 'ETH', 10.0000000000001), '10.00000000', 'ETH 10.0000000000001 -> 10.00000000';
    is formatnumber('amount', 'ETC', 10),               '10.00000000', 'ETC 10 -> 10.00000000';
    is formatnumber('amount', 'ETC', 10.000001),        '10.00000100', 'ETC 10.000001 -> 10.00000100';
    is formatnumber('amount', 'ETC', 10.0000000000001), '10.00000000', 'ETC 10.0000000000001 -> 10.00000000';

};

subtest 'check price precision' => sub {
    is formatnumber('price', 'USD', 10),               '10.00',       'USD 10 -> 10.00';
    is formatnumber('price', 'USD', 10.000001),        '10.00',       'USD 10.000001 -> 10.00';
    is formatnumber('price', 'EUR', 10.000001),        '10.00',       'EUR 10.000001 -> 10.00';
    is formatnumber('price', 'JPY', 10.000001),        '10',          'JPY 10.000001 -> 10';
    is formatnumber('price', 'BTC', 10),               '10.00000000', 'BTC 10 -> 10.00000000';
    is formatnumber('price', 'BTC', 10.000001),        '10.00000100', 'BTC 10.000001 -> 10.00000100';
    is formatnumber('price', 'BTC', 10.0000000000001), '10.00000000', 'BTC 10.0000000000001 -> 10.00000000';
    is formatnumber('price', 'ETH', 10),               '10.00000000', 'ETH 10 -> 10.00000000';
    is formatnumber('price', 'ETH', 10.000001),        '10.00000100', 'ETH 10.000001 -> 10.00000100';
    is formatnumber('price', 'ETH', 10.0000000000001), '10.00000000', 'ETH 10.0000000000001 -> 10.00000000';
    is formatnumber('price', 'ETC', 10),               '10.00000000', 'ETC 10 -> 10.00000000';
    is formatnumber('price', 'ETC', 10.000001),        '10.00000100', 'ETC 10.000001 -> 10.00000100';
    is formatnumber('price', 'ETC', 10.0000000000001), '10.00000000', 'ETC 10.0000000000001 -> 10.00000000';

};

done_testing();
