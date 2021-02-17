use strict;
use warnings;
use Test::More;

use BOM::TradingPlatform;

my $dxtrader = BOM::TradingPlatform->new('dxtrader');
isa_ok($dxtrader, 'BOM::TradingPlatform::DXTrader');

my $account = $dxtrader->new_account({clearing_code => 'TEST'});

is $account->{clearing_code}, 'TEST', 'Account created';

done_testing();
