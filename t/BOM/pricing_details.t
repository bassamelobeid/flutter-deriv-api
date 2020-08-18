#!/usr/bin/perl

use strict;
use warnings;

use BOM::PricingDetails;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Test::More;
use Test::Exception;
use Test::FailWarnings;
use Date::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

my $u   = create_underlying('frxUSDJPY');
my $now = time;
foreach my $rd ($now - 5 .. $now) {
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            recorded_date => Date::Utility->new($rd),
            underlying    => $u
        });
}

subtest '_fetch_historical_surface_date' => sub {
    my $bet = produce_contract('CALL_frxUSDJPY_100_' . $now . '_' . ($now + 3600) . '_S0P_0', 'USD');
    my $pd  = BOM::PricingDetails->new(bet => $bet);
    throws_ok { $pd->_fetch_historical_surface_date() } qr/Must pass in symbol to fetch surface dates./, 'throws error if no symbol';
    lives_ok {
        my $dates = $pd->_fetch_historical_surface_date({symbol => 'frxUSDJPY'});
        is scalar(@$dates), 1, 'got one date by default';
        $dates = $pd->_fetch_historical_surface_date({
            symbol  => 'frxUSDJPY',
            back_to => 5
        });
        is scalar(@$dates), 5, 'got the requested five dates';
    }
    'fetches dates';
};

done_testing;
