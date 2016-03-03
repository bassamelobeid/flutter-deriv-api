use strict;
use warnings;

use Test::More tests => 30;
use Test::Exception;
use Test::NoWarnings;

use Date::Utility;

use BOM::Market::Underlying;
use BOM::Market::Registry;

my $index_symbol   = 'GDAXI';
my $forex_symbol   = 'frxUSDJPY';
my $unknown_symbol = 'unknown_symbol';
my $yesterday      = Date::Utility->new(time - 86400);

my $index  = new_ok('BOM::Market::Underlying' => [$index_symbol]);
my $index2 = new_ok('BOM::Market::Underlying' => [$index_symbol]);
my $index3 = new_ok('BOM::Market::Underlying' => [$index_symbol, $yesterday]);
my $index4 = new_ok('BOM::Market::Underlying' => [$index_symbol, $yesterday]);
my $index5 = new_ok('BOM::Market::Underlying' => [{symbol => $index_symbol}]);
my $index6 = new_ok(
    'BOM::Market::Underlying' => [{
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

my $forex  = new_ok('BOM::Market::Underlying' => [$forex_symbol]);
my $forex2 = new_ok('BOM::Market::Underlying' => [$forex_symbol]);

is $forex,   $forex2, 'Forex objects are the same';
isnt $forex, $index,  'But different from index';

new_ok('BOM::Market::Underlying' => [$unknown_symbol]);
new_ok('BOM::Market::Underlying' => [$unknown_symbol, $yesterday]);

throws_ok { BOM::Market::Underlying->new } qr/No symbol provided to constructor/, 'Can not construct without symbol';
throws_ok { BOM::Market::Underlying->new({sym => $forex_symbol}) } qr/No symbol provided to constructor/,
    'Can not construct via hashref without symbol';
throws_ok { BOM::Market::Underlying->new($forex_symbol, time) } qr/Attribute \(for_date\) does not pass the type constraint/,
    'for_date must be Date::Utility';

new_ok(
    'BOM::Market::Underlying' => [{
            symbol => 'frxUSDJPY',
            market => 'forex'
        }]);
new_ok(
    'BOM::Market::Underlying' => [{
            symbol => 'frxUSDJPY',
            market => 'bomba'
        }]);
new_ok(
    'BOM::Market::Underlying' => [{
            symbol => $unknown_symbol,
            market => 'forex'
        }]);

my $market = BOM::Market::Registry->get('forex');
new_ok(
    'BOM::Market::Underlying' => [{
            symbol => 'frxUSDJPY',
            market => $market
        }]);
throws_ok { BOM::Market::Underlying->new({symbol => $unknown_symbol, market => 'bomba'}) } qr/Attribute \(market\) does not pass the type constraint/;

my $fake_market = Date::Utility->new();
throws_ok { BOM::Market::Underlying->new({symbol => $unknown_symbol, market => $fake_market}) }
qr/Attribute \(market\) does not pass the type constraint/;
new_ok(
    'BOM::Market::Underlying' => [{
            symbol => 'frxUSDJPY',
            market => $fake_market
        }]);
