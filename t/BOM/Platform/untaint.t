#!/etc/rmg/bin/perl

use strict;
use warnings;

use utf8;
use charnames ':full';
use Test::More qw(no_plan);

use CGI::Untaint;
use BOM::Platform::Untaint;

my $handler = CGI::Untaint->new(
    {INCLUDE_PATH => 'BOM::Platform::Untaint'},
    currency1 => 'USD',
    currency2 => 'xxxGBP111',
    currency3 => 'eur',
    currency4 => '',
    currency5 => undef,

    market1 => 'stocks',
    market2 => 'anyword',

    bet_type1 => 'CALL',
    bet_type2 => 'ANYWORD',
    bet_type3 => '>|attack!|<',

    underlying1 => 'frxUSDJPY',
    underlying2 => 'ANYWORD',
    underlying3 => '>|attack!|<',

    duration1 => '12m',
    duration2 => '5m',
    duration3 => '30s',
    duration4 => '18.5m',
    duration5 => '1d',
    duration6 => '1.5d',
    duration7 => '25-Dec-09',
    duration8 => 1261381082,
    duration9 => '0d',

    duration_unit1 => 'd',
    duration_unit2 => 'z',
    duration_unit3 => 'mm',
    duration_unit4 => '',

    epoch1 => 1261381082,
    epoch2 => 1261,
    epoch3 => '31-Jan-08',
    epoch4 => '|>random!',

    integer1 => 20,
    integer2 => 20.1,
    integer3 => 10.0,
    integer4 => '10.0',
    integer5 => 'integer',
    integer6 => '%ff%17',
    integer7 => +9,
    integer8 => -4,
    integer9 => "\N{THAI DIGIT ONE}",

    relative_barrier1  => '+0',
    relative_barrier2  => '+0.02',
    relative_barrier3  => '+0.0006',
    relative_barrier4  => '-0.0012',
    relative_barrier5  => '-1.0012',
    relative_barrier6  => '1.8699',
    relative_barrier7  => '5214',
    relative_barrier8  => 'S0P',
    relative_barrier9  => 'S-1P',
    relative_barrier10 => 'something',
    relative_barrier11 => '+0.1',

    absolute_barrier1  => '+0',
    absolute_barrier2  => '+0.02',
    absolute_barrier3  => '0.0002',
    absolute_barrier4  => '-1.0012',
    absolute_barrier5  => '1.8699',
    absolute_barrier6  => '89.55',
    absolute_barrier7  => '5214',
    absolute_barrier8  => '100000',
    absolute_barrier9  => 'S0P',
    absolute_barrier10 => 'S-1P',
    absolute_barrier11 => 'something',

    shortcode1 => 'CALL_FRXGBPUSD_2_1265849680_1265849980_S0P_0',
    shortcode2 => 'call_FRXGBPUSD_2_1265849680_1265849980_S0P_0',
    shortcode3 => 'AZ_-123',
    shortcode4 => 'CALL|FRXGBPUSD>2<1265849680*1265849980$S0P@0',
    shortcode5 => '',

    amount_type1 => 'payout',
    amount_type2 => 'stake',
    amount_type3 => 'credit',

    barrier_type1 => 'relative',
    barrier_type2 => 'absolute',
    barrier_type3 => 'anything|else',

    granter_loginids1 => 'CR90010',
    granter_loginids2 => "CR90010\n\nCR90011\nCR90012",
    granter_loginids3 => "CR90010,CR90011,CR90012",
    granter_loginids4 => "aif44o\n1|c*'",

    expiry_type1 => 'duration',
    expiry_type2 => 'motown',
    expiry_type3 => 'tick5',

    date_yyyymmdd1 => '1960-10-01',
    date_yyyymmdd2 => 'ab',
    date_yyyymmdd3 => '',

    stop_type1 => "dollar",
    stop_type2 => "point",
    stop_type3 => "eh",

    form_name2  => 'risefall',
    form_name3  => 'digits',
    form_name4  => 'asian',
    form_name5  => 'higherlower',
    form_name6  => 'touchnotouch',
    form_name7  => 'staysinout',
    form_name8  => 'endsinout',
    form_name9  => 'spreads',
    form_name10 => 'form_name',
    form_name11 => 'evenodd',
    form_name12 => 'overunder',

    floating_point1 => "1.1",
    floating_point2 => "-1.1",
    floating_point3 => ".1",
    floating_point4 => "-.1",
    floating_point5 => "1.A",
    floating_point6 => "1",
    floating_point7 => "."
);

is($handler->extract(-as_form_name => 'form_name2'),  'risefall');
is($handler->extract(-as_form_name => 'form_name3'),  'digits');
is($handler->extract(-as_form_name => 'form_name4'),  'asian');
is($handler->extract(-as_form_name => 'form_name5'),  'higherlower');
is($handler->extract(-as_form_name => 'form_name6'),  'touchnotouch');
is($handler->extract(-as_form_name => 'form_name7'),  'staysinout');
is($handler->extract(-as_form_name => 'form_name8'),  'endsinout');
is($handler->extract(-as_form_name => 'form_name9'),  'spreads');
is($handler->extract(-as_form_name => 'form_name10'), undef);
is($handler->extract(-as_form_name => 'form_name11'), 'evenodd');
is($handler->extract(-as_form_name => 'form_name12'), 'overunder');

is($handler->extract(-as_floating_point => 'floating_point1'), "1.1",);
is($handler->extract(-as_floating_point => 'floating_point2'), "-1.1",);
is($handler->extract(-as_floating_point => 'floating_point3'), ".1",);
is($handler->extract(-as_floating_point => 'floating_point4'), "-.1",);
is($handler->extract(-as_floating_point => 'floating_point5'), undef,);
is($handler->extract(-as_floating_point => 'floating_point6'), "1",);
is($handler->extract(-as_floating_point => 'floating_point7'), undef,);

is($handler->extract(-as_stop_type => 'stop_type1'), 'dollar', '"dollar" qualifies as valid stop type');
is($handler->extract(-as_stop_type => 'stop_type2'), 'point',  '"point" qualifies as valid stop type');
is($handler->extract(-as_stop_type => 'stop_type3'), undef,    '"eh" is not a valid expiry type');

is($handler->extract(-as_expiry_type => 'expiry_type1'), 'duration', '"duration" qualifies as valid expiry type');
is($handler->extract(-as_expiry_type => 'expiry_type2'), undef,      '"motown" is not a valid expiry type');
is($handler->extract(-as_expiry_type => 'expiry_type3'), undef,      '"tick5" is not a valid expiry type');

is($handler->extract(-as_date_yyyymmdd => 'date_yyyymmdd1'), '1960-10-01', '"1960-10-01" is a valid date format');
is($handler->extract(-as_date_yyyymmdd => 'date_yyyymmdd2'), undef,        '"ab" is not a valid date format');
is($handler->extract(-as_date_yyyymmdd => 'date_yyyymmdd3'), undef,        'an empty string is not a valid date');

is($handler->extract(-as_currency => 'currency1'), 'USD', 'get currency from "USD"');
is($handler->extract(-as_currency => 'currency2'), undef, 'cannot take currency from string with other characters; has to be exact');
is($handler->extract(-as_currency => 'currency3'), undef, 'currency string must be uppercase');
is($handler->extract(-as_currency => 'currency4'), undef, 'currency string must be empty');
is($handler->extract(-as_currency => 'currency5'), undef, 'currecny value must not be null');

is($handler->extract(-as_market => 'market1'), 'stocks', '"stocks" is one of our markets');
is($handler->extract(-as_market => 'market2'), undef,    '"anyword" is not one of our markets');

is($handler->extract(-as_bet_type => 'bet_type1'), 'CALL',    'CALL is a bet type');
is($handler->extract(-as_bet_type => 'bet_type2'), 'ANYWORD', 'In fact,  any "word" is a bet type');
is($handler->extract(-as_bet_type => 'bet_type3'), undef,     '..but not anything');

is($handler->extract(-as_underlying_symbol => 'underlying1'), 'frxUSDJPY', 'frxUSDJPY is an underlying');
is($handler->extract(-as_underlying_symbol => 'underlying2'), 'ANYWORD',   'In fact,  any "word" is currently an underlying');
is($handler->extract(-as_underlying_symbol => 'underlying3'), undef,       '..but not anything');

is($handler->extract(-as_duration => 'duration1'), '12m', '12m is a valid duration');
is($handler->extract(-as_duration => 'duration2'), '5m',  '5m is a valid duration');
is($handler->extract(-as_duration => 'duration3'), '30s', '30s is a valid duration');
is($handler->extract(-as_duration => 'duration4'), undef, '18.5m is not a valid duration');
is($handler->extract(-as_duration => 'duration5'), '1d',  '1d is a valid duration');
is($handler->extract(-as_duration => 'duration6'), undef, '1.5d is not a valid duration');
is($handler->extract(-as_duration => 'duration7'), undef, '25-Dec-09 is not a valid duration');
is($handler->extract(-as_duration => 'duration8'), undef, '1261381082 is not a valid duration');
is($handler->extract(-as_duration => 'duration9'), '0d',  '0d is a valid duration');

is($handler->extract(-as_duration_unit => 'duration_unit1'), 'd',   '"d" is a valid unit of measure for duration');
is($handler->extract(-as_duration_unit => 'duration_unit2'), undef, '"z" is not a valid unit of measure for duration');
is($handler->extract(-as_duration_unit => 'duration_unit3'), undef, '"mm" is not a valid unit of measure for duration');
is($handler->extract(-as_duration_unit => 'duration_unit4'), undef, 'unit of measure cannot be empty');

is($handler->extract(-as_epoch => 'epoch1'), 1261381082, '1261381082 is a valid epoch');
is($handler->extract(-as_epoch => 'epoch2'), 1261,       '1261 is a valid epoch (albeit quite short)');
is($handler->extract(-as_epoch => 'epoch3'), undef,      'our date format is not an epoch');
is($handler->extract(-as_epoch => 'epoch4'), undef,      'random strings are not epochs');

is($handler->extract(-as_integer => 'integer1'), 20,    '20 is an integer');
is($handler->extract(-as_integer => 'integer2'), undef, '20.1 is not an integer');
is($handler->extract(-as_integer => 'integer3'), 10.0,  '10.0 evaluates to an integer');
is($handler->extract(-as_integer => 'integer4'), undef, '10.0 as a string does not');
is($handler->extract(-as_integer => 'integer5'), undef, 'the string "integer" is not an integer');
is($handler->extract(-as_integer => 'integer6'), undef, 'the string "%ff%17" is not an integer');
is($handler->extract(-as_integer => 'integer7'), +9,    '+9 is a valid integer');
is($handler->extract(-as_integer => 'integer8'), -4,    '-4 is a valid integer');
#is($handler->extract(-as_integer => 'integer9'), undef, 'thai digits are not allowed in integers');

is($handler->extract(-as_relative_barrier => 'relative_barrier1'), '+0',      'the ATM relative barrier');
is($handler->extract(-as_relative_barrier => 'relative_barrier2'), '+0.02',   'plus two pips from the spot');
is($handler->extract(-as_relative_barrier => 'relative_barrier3'), '+0.0006', 'a small positive adjustment');
is($handler->extract(-as_relative_barrier => 'relative_barrier4'), '-0.0012', 'a small negative adjustment');
is($handler->extract(-as_relative_barrier => 'relative_barrier5'), '-1.0012', 'a larger negative adjustment');
is($handler->extract(-as_relative_barrier => 'relative_barrier6'),
    '1.8699', 'an absolute barrier, but technically allowed as it is quite low so could be relative.');
is($handler->extract(-as_relative_barrier => 'relative_barrier8'),  'S0P',  'a relative barrier as stored in our shortcodes');
is($handler->extract(-as_relative_barrier => 'relative_barrier9'),  'S-1P', 'a relative barrier as stored in our shortcodes');
is($handler->extract(-as_relative_barrier => 'relative_barrier10'), undef,  '"something" is not valid');
is($handler->extract(-as_relative_barrier => 'relative_barrier11'), '+0.1', 'testing +0.1');

is($handler->extract(-as_absolute_barrier => 'absolute_barrier1'), undef, 'the ATM relative barrier, invalid as an absolute as it is "zero"');
is($handler->extract(-as_absolute_barrier => 'absolute_barrier2'),
    undef, 'plus two pips from the spot, not allowed as an absolute as it has a "+" char in it');
is($handler->extract(-as_absolute_barrier => 'absolute_barrier3'),  '0.0002', 'a very low but still valid absolute barrier');
is($handler->extract(-as_absolute_barrier => 'absolute_barrier4'),  undef,    'negative values not valid as absolute barriers');
is($handler->extract(-as_absolute_barrier => 'absolute_barrier5'),  '1.8699', 'an absolute barrier');
is($handler->extract(-as_absolute_barrier => 'absolute_barrier6'),  '89.55',  'an absolute barrier to two decimal places');
is($handler->extract(-as_absolute_barrier => 'absolute_barrier7'),  '5214',   'a high-value absolute barrier');
is($handler->extract(-as_absolute_barrier => 'absolute_barrier9'),  undef,    'the format stored in our shortcodes is not valid from %input');
is($handler->extract(-as_absolute_barrier => 'absolute_barrier10'), undef,    'another not allowed shortcode format');
is($handler->extract(-as_absolute_barrier => 'absolute_barrier11'), undef,    '"something" is not valid');

is($handler->extract(-as_shortcode => 'shortcode1'), 'CALL_FRXGBPUSD_2_1265849680_1265849980_S0P_0', 'a normal valid shortcode');
is($handler->extract(-as_shortcode => 'shortcode2'), undef, 'lowercase not allowed');
is($handler->extract(-as_shortcode => 'shortcode3'), 'AZ_-123', 'we now handle bad shortcodes elsewhere, so this will pass.');
is($handler->extract(-as_shortcode => 'shortcode4'), undef,     'no funny characters will get through');
is($handler->extract(-as_shortcode => 'shortcode5'), undef,     'empty string is not a shortcode');

is($handler->extract(-as_amount_type => 'amount_type1'), 'payout', 'payout is a valid amount_type');
is($handler->extract(-as_amount_type => 'amount_type2'), 'stake',  'stake is a valid amount_type');
is($handler->extract(-as_amount_type => 'amount_type3'), undef,    'undefined amount_type values are not allowed');

is($handler->extract(-as_barrier_type => 'barrier_type1'), 'relative', 'relative is a valid barrier_type');
is($handler->extract(-as_barrier_type => 'barrier_type2'), 'absolute', 'absolute is a valid barrier_type');
is($handler->extract(-as_barrier_type => 'barrier_type3'), undef,      'anything else just isnt');

# Tests added from found bugs:
'UUUUU' =~ /(U)/;    # $1 now contains "U"
is($handler->extract(-as_epoch => 1261458000), undef, 'regex checks should be accurate even if $1 is set from a previous regex match');

