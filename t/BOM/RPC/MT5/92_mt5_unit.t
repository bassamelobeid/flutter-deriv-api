use strict;
use warnings;
use Test::More;

use BOM::RPC::v3::MT5::Account;

my %account_lc_short = (
    'real\malta'                    => 'malta',
    'real\iom'                      => 'iom',
    'real\svg_financial'             => 'svg',
    'real\labuan_financial_stp'          => 'labuan',
    'real\maltainvest_financial'     => 'maltainvest',
    'real\maltainvest_financial_GBP' => 'maltainvest',
    'real\svg'                      => 'svg',
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
