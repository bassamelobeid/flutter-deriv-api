use strict;
use warnings;
use Test::More;

use BOM::RPC::v3::MT5::Account;

my %account_lc_short = (
    'real\malta'                    => 'malta',
    'real\iom'                      => 'iom',
    'real\vanuatu_standard'         => 'vanuatu',
    'real\labuan_advanced'          => 'labuan',
    'real\maltainvest_standard'     => 'maltainvest',
    'real\maltainvest_standard_GBP' => 'maltainvest',
    'real\svg_mamm_2343'            => 'svg',
    'real\svg'                      => 'svg',
);

subtest 'Extract landing company short' => sub {

    for my $each_mt5_group (keys %account_lc_short) {

        is(
            BOM::RPC::v3::MT5::Account::_fetch_mt5_lc({group => $each_mt5_group}),
            $account_lc_short{$each_mt5_group},
            "Correct lc_short for $each_mt5_group"
        );

    }

    # if it fails, it returns a future
    is(BOM::RPC::v3::MT5::Account::_fetch_mt5_lc({group => 'wrong\\mt5_group'}), undef, 'wrong group no return');
};

done_testing();
