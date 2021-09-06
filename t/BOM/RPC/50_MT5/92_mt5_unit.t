use strict;
use warnings;
use Test::More;

use BOM::RPC::v3::MT5::Account;

my %account_lc_short = (
    'real\malta'                              => 'malta',
    'real\iom'                                => 'iom',
    'real\svg_financial'                      => 'svg',
    'real\labuan_financial_stp'               => 'labuan',
    'real\maltainvest_financial'              => 'maltainvest',
    'real\maltainvest_financial_GBP'          => 'maltainvest',
    'real\svg'                                => 'svg',
    'real01\synthetic\malta_std_eur'          => 'malta',
    'real01\synthetic\iom_std_eur'            => 'iom',
    'real01\financial\svg_std-hr_usd'         => 'svg',
    'real01\financial\labuan_stp_usd'         => 'labuan',
    'real01\financial\maltainvest_std-hr_eur' => 'maltainvest',
    'real01\financial\maltainvest_std-hr_gbp' => 'maltainvest',
    'real01\synthetic\svg_std_usd'            => 'svg',
);

subtest 'Extract landing company short' => sub {

    for my $each_mt5_group (keys %account_lc_short) {

        is(
            BOM::RPC::v3::MT5::Account::_fetch_mt5_lc({group => $each_mt5_group})->short,
            $account_lc_short{$each_mt5_group},
            "Correct lc_short for $each_mt5_group"
        );

    }

    # if it fails, it returns a future
    is(BOM::RPC::v3::MT5::Account::_fetch_mt5_lc({group => 'wrong\\mt5_group'}), undef, 'wrong group no return');
};

done_testing();
