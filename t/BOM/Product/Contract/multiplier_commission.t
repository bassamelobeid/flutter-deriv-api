#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use LandingCompany::Registry;
use Date::Utility;

my $offerings = LandingCompany::Registry::get('virtual')->basic_offerings({
    loaded_revision => 1,
    action          => 'buy'
});
my @symbols = $offerings->query({contract_category => 'multiplier'}, ['underlying_symbol']);

subtest 'commission for underlying' => sub {
    my %expected_comm = (
        R_10        => [100, 5.0366490434625e-05],
        R_25        => [50,  0.000125916226086562],
        R_50        => [20,  0.000251832452173125],
        R_75        => [15,  0.000377748678259687],
        R_100       => [10,  0.000503664904346249],
        '1HZ10V'    => [100, 3.56144869308907e-05],
        '1HZ25V'    => [50,  0.000125916226086562],
        '1HZ50V'    => [20,  0.000251832452173125],
        '1HZ75V'    => [15,  0.000377748678259687],
        '1HZ100V'   => [10,  0.000356144869308907],
        'frxEURJPY' => [30,  0.0002],
        'frxAUDUSD' => [50,  0.0002],
        'frxGBPAUD' => [20,  0.0004],
        'frxUSDJPY' => [50,  0.0002],
        'frxUSDCHF' => [50,  0.00015],
        'frxEURCAD' => [20,  0.0003],
        'frxGBPUSD' => [50,  0.0002],
        'frxEURGBP' => [30,  0.0003],
        'frxEURUSD' => [50,  0.00015],
        'frxGBPJPY' => [30,  0.00025],
        'frxEURAUD' => [20,  0.0003],
        'frxAUDJPY' => [20,  0.0003],
        'frxEURCHF' => [20,  0.00025],
        'frxUSDCAD' => [50,  0.0002],
        CRASH1000   => [100, 0.00025],
        CRASH500    => [100, 0.00025],
        BOOM1000    => [100, 0.00025],
        BOOM500     => [100, 0.00025],
        stpRNG      => [500, 0.00001],
        WLDEUR      => [50,  0.00015],
        WLDUSD      => [50,  0.00015],
        WLDGBP      => [30,  0.00020],
        WLDAUD      => [20,  0.00025],
        WLDXAU      => [15,  0.0003],
        cryBTCUSD   => [10,  0.001],
        cryETHUSD   => [10,  0.001],
        cryBNBUSD   => [10,  0.0015],
        cryBCHUSD   => [10,  0.0015],
        cryLTCUSD   => [10,  0.0015],
        cryXRPUSD   => [10,  0.0015],
        cryEOSUSD   => [10,  0.01],
        cryZECUSD   => [10,  0.01],
        cryXMRUSD   => [10,  0.01],
        cryDSHUSD   => [10,  0.01],
        JD10        => [100, 0.000024],
        JD25        => [100, 0.000059],
        JD50        => [100, 0.000118],
        JD75        => [15,  0.000177],
        JD100       => [100, 0.000236],
        '1HZ200V'   => [1,   0.00036],
        '1HZ300V'   => [1,   0.00053],
        CRASH300N   => [1,   0.0002],                 #minimum commission
        BOOM300N    => [1,   0.0002],                 #minimum commission
    );
    # fixed time because commission for forex is a function of spread seasonality and economic events
    my $now  = Date::Utility->new('2020-06-10');
    my $args = {
        bet_type     => 'multup',
        stake        => 100,
        currency     => 'USD',
        date_start   => $now,
        date_pricing => $now,
    };

    foreach my $symbol (@symbols) {
        $args->{underlying} = $symbol;
        if ($expected_comm{$symbol}) {
            $args->{multiplier} = $expected_comm{$symbol}->[0];
            my $c = produce_contract($args);
            is $c->commission + 0, $expected_comm{$symbol}->[1] * $c->commission_multiplier, "commission for $symbol is $expected_comm{$symbol}->[1]";
        } else {
            fail "config not found for $symbol";
        }
    }
};

done_testing();
