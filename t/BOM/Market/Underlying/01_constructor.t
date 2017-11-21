use strict;
use warnings;

use Test::More tests => 30;
use Test::Exception;
use Test::Warnings;

use Date::Utility;

use BOM::MarketData qw(create_underlying);
use Finance::Asset::Market::Registry;

my $index_symbol   = 'GDAXI';
my $forex_symbol   = 'frxUSDJPY';
my $unknown_symbol = 'unknown_symbol';
my $yesterday      = Date::Utility->new(time - 86400);

my $index  = new_ok('Quant::Framework::Underlying' => [$index_symbol]);
my $index2 = new_ok('Quant::Framework::Underlying' => [$index_symbol]);
my $index3 = new_ok('Quant::Framework::Underlying' => [$index_symbol, $yesterday]);
my $index4 = new_ok('Quant::Framework::Underlying' => [$index_symbol, $yesterday]);
my $index5 = new_ok('Quant::Framework::Underlying' => [{symbol => $index_symbol}]);
my $index6 = new_ok(
    'Quant::Framework::Underlying' => [{
            symbol         => $index_symbol,
            weekend_weight => 0.75
        }]);

is $index->for_date,      undef,           'for_date undef when not included in constructor';
isa_ok $index3->for_date, 'Date::Utility', 'for_date when included in constructor';

is $index,    $index2, 'Second object is cached copy of first';
isnt $index3, $index,  'Dated object is not cached copy of first';
isnt $index4, $index3, 'Dated objects are not cached';

is $index5,   $index,  'Symbol-only hashref is same as just symbol';
isnt $index6, $index5, 'Different objects with extra arguments in the hashref';

my $forex  = new_ok('Quant::Framework::Underlying' => [$forex_symbol]);
my $forex2 = new_ok('Quant::Framework::Underlying' => [$forex_symbol]);

is $forex,   $forex2, 'Forex objects are the same';
isnt $forex, $index,  'But different from index';

new_ok('Quant::Framework::Underlying' => [$unknown_symbol]);
new_ok('Quant::Framework::Underlying' => [$unknown_symbol, $yesterday]);

throws_ok { create_underlying } qr/No symbol provided to constructor/, 'Can not construct without symbol';
throws_ok { create_underlying({sym => $forex_symbol}) } qr/No symbol provided to constructor/, 'Can not construct via hashref without symbol';
throws_ok { create_underlying($forex_symbol, time) } qr/Attribute \(for_date\) does not pass the type constraint/, 'for_date must be Date::Utility';

new_ok(
    'Quant::Framework::Underlying' => [{
            symbol => 'frxUSDJPY',
            market => 'forex'
        }]);
new_ok(
    'Quant::Framework::Underlying' => [{
            symbol => 'frxUSDJPY',
            market => 'bomba'
        }]);
new_ok(
    'Quant::Framework::Underlying' => [{
            symbol => $unknown_symbol,
            market => 'forex'
        }]);

my $market = Finance::Asset::Market::Registry->get('forex');
new_ok(
    'Quant::Framework::Underlying' => [{
            symbol => 'frxUSDJPY',
            market => $market
        }]);
throws_ok { create_underlying({symbol => $unknown_symbol, market => 'bomba'}) } qr/Attribute \(market\) does not pass the type constraint/;

my $fake_market = Date::Utility->new();
throws_ok { create_underlying({symbol => $unknown_symbol, market => $fake_market}) } qr/Attribute \(market\) does not pass the type constraint/;
new_ok(
    'Quant::Framework::Underlying' => [{
            symbol => 'frxUSDJPY',
            market => $fake_market
        }]);
