use strict;
use warnings;

use Test::Most;
use Price::Calculator qw/get_amount_precision get_price_precision/;

subtest 'check amount precision' => sub {
    is sprintf('%' . get_amount_precision('USD') . 'f', 10),               '10.00',       'USD 10 -> 10.00';
    is sprintf('%' . get_amount_precision('USD') . 'f', 10.000001),        '10.00',       'USD 10.000001 -> 10.00';
    is sprintf('%' . get_amount_precision('EUR') . 'f', 10.000001),        '10.00',       'EUR 10.000001 -> 10.00';
    is sprintf('%' . get_amount_precision('JPY') . 'f', 10.000001),        '10.00',       'JPY 10.000001 -> 10.00';
    is sprintf('%' . get_amount_precision('BTC') . 'f', 10),               '10.00000000', 'BTC 10 -> 10.00000000';
    is sprintf('%' . get_amount_precision('BTC') . 'f', 10.000001),        '10.00000100', 'BTC 10.000001 -> 10.00000100';
    is sprintf('%' . get_amount_precision('BTC') . 'f', 10.0000000000001), '10.00000000', 'BTC 10.0000000000001 -> 10.00000000';
    is sprintf('%' . get_amount_precision('ETH') . 'f', 10),               '10.00000000', 'ETH 10 -> 10.00000000';
    is sprintf('%' . get_amount_precision('ETH') . 'f', 10.000001),        '10.00000100', 'ETH 10.000001 -> 10.00000100';
    is sprintf('%' . get_amount_precision('ETH') . 'f', 10.0000000000001), '10.00000000', 'ETH 10.0000000000001 -> 10.00000000';
};

subtest 'check price precision' => sub {
    is sprintf('%' . get_price_precision('USD') . 'f', 10),               '10.00',       'USD 10 -> 10.00';
    is sprintf('%' . get_price_precision('USD') . 'f', 10.000001),        '10.00',       'USD 10.000001 -> 10.00';
    is sprintf('%' . get_price_precision('EUR') . 'f', 10.000001),        '10.00',       'EUR 10.000001 -> 10.00';
    is sprintf('%' . get_price_precision('JPY') . 'f', 10.000001),        '10',          'JPY 10.000001 -> 10';
    is sprintf('%' . get_price_precision('BTC') . 'f', 10),               '10.00000000', 'BTC 10 -> 10.00000000';
    is sprintf('%' . get_price_precision('BTC') . 'f', 10.000001),        '10.00000100', 'BTC 10.000001 -> 10.00000100';
    is sprintf('%' . get_price_precision('BTC') . 'f', 10.0000000000001), '10.00000000', 'BTC 10.0000000000001 -> 10.00000000';
    is sprintf('%' . get_price_precision('ETH') . 'f', 10),               '10.00000000', 'ETH 10 -> 10.00000000';
    is sprintf('%' . get_price_precision('ETH') . 'f', 10.000001),        '10.00000100', 'ETH 10.000001 -> 10.00000100';
    is sprintf('%' . get_price_precision('ETH') . 'f', 10.0000000000001), '10.00000000', 'ETH 10.0000000000001 -> 10.00000000';
};

done_testing();
