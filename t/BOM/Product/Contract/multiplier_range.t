#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::FailWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

my $offerings = LandingCompany::Registry::get('virtual')->basic_offerings({
    loaded_revision => 1,
    action          => 'buy'
});
my @symbols = $offerings->query({contract_category => 'multiplier'}, ['underlying_symbol']);

subtest 'multiplier range' => sub {
    my $expected = {
        'frxEURJPY' => [30,  50,   100,  150, 300],
        'frxAUDUSD' => [50,  100,  150,  250, 500],
        'R_25'      => [50,  100,  150,  250, 500],
        'frxGBPAUD' => [20,  30,   50,   100, 200],
        'frxUSDJPY' => [50,  100,  150,  250, 500],
        'frxUSDCHF' => [50,  100,  150,  250, 500],
        'R_50'      => [20,  40,   60,   100, 200],
        'frxEURCAD' => [20,  30,   50,   100, 200],
        'frxGBPUSD' => [50,  100,  150,  250, 500],
        'R_10'      => [100, 200,  300,  500, 1000],
        'frxEURGBP' => [30,  50,   100,  150, 300],
        'frxEURUSD' => [50,  100,  150,  250, 500],
        'frxGBPJPY' => [30,  50,   100,  150, 300],
        'R_75'      => [15,  30,   50,   75,  150],
        'frxEURAUD' => [20,  30,   50,   100, 200],
        'frxAUDJPY' => [20,  30,   50,   100, 200],
        'frxEURCHF' => [20,  30,   50,   100, 200],
        'R_100'     => [10,  20,   30,   50,  100],
        '1HZ10V'    => [100, 200,  300,  500, 1000],
        '1HZ25V'    => [50,  100,  150,  250, 500],
        '1HZ50V'    => [20,  40,   60,   100, 200],
        '1HZ75V'    => [15,  30,   50,   75,  150],
        '1HZ100V'   => [10,  20,   30,   50,  100],
        'frxUSDCAD' => [50,  100,  150,  250, 500],
        CRASH1000   => [100, 200,  300,  400],
        CRASH500    => [100, 200,  300,  400],
        BOOM1000    => [100, 200,  300,  400],
        BOOM500     => [100, 200,  300,  400],
        stpRNG      => [500, 1000, 2000, 3000, 4000],
        WLDEUR      => [50,  100,  150,  250,  500],
        WLDUSD      => [50,  100,  150,  250,  500],
        WLDGBP      => [30,  50,   100,  150,  300],
        WLDAUD      => [20,  30,   50,   100,  200],
        cryBTCUSD   => [10,  20,   30,   40,   50],
        cryETHUSD   => [10,  20,   30,   40,   50],
        cryBNBUSD   => [10,  20,   30],
        cryBCHUSD   => [10,  20,   30],
        cryLTCUSD   => [10,  20,   30],
        cryXRPUSD   => [10,  20,   30],
        cryEOSUSD   => [5,   10],
        cryZECUSD   => [5,   10],
        cryXMRUSD   => [5,   10],
        cryDSHUSD   => [5,   10],
        JD10        => [100, 200, 300, 500, 1000],
        JD25        => [50,  100, 150, 250, 500],
        JD50        => [20,  40,  60,  100, 200],
        JD75        => [15,  30,  50,  75,  150],
        JD100       => [10,  20,  30,  50,  100],
    };
    my $args = {
        bet_type   => 'multup',
        stake      => 100,
        currency   => 'USD',
        multiplier => 100,
    };

    foreach my $symbol (@symbols) {
        $args->{underlying} = $symbol;
        if (my $range = $expected->{$symbol}) {
            foreach my $multiplier (@$range) {
                $args->{multiplier} = $multiplier;
                my $c = produce_contract($args);
                ok !$c->_validate_multiplier_range();
            }
        } else {
            fail "multiplier range config not found for $symbol";
        }
    }
};

done_testing();
