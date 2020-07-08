package Test::BOM::RPC::Accounts;
use strict;
use warnings;
# %ACCOUNTS and %DETAILS are shared between four files, and should be kept in-sync to avoid test failures
#   t/BOM/RPC/MT5
#   t/BOM/RPC/05_accounts.t
#   t/BOM/RPC/Cashier/20_transfer_between_accounts.t
#   t/lib/mock_binary_mt5.pl

our %MT5_ACCOUNTS = (
    'demo\svg_financial'             => '00000001',
    'demo\svg_financial_stp'             => '00000002',
    'demo\labuan_financial'          => '00000003',
    'demo\labuan_financial_stp'          => '00000004',
    'real\malta'                    => '00000010',
    'real\maltainvest_financial'     => '00000011',
    'real\maltainvest_financial_GBP' => '00000012',
    'real\svg'                      => '00000013',
    'real\svg_financial'             => '00000014',
    'real\labuan_financial_stp'          => '00000015',
);

our %ACCOUNT_DETAILS = (
    password => {
        main     => 'Efgh4567',
        investor => 'Abcd1234',
    },
    email           => 'test.account@binary.com',
    name            => 'Meta traderman',
    group           => 'real\svg',
    country         => 'Malta',
    balance         => '1234',
    display_balance => '1234.00',
    rights          => 483,
);

our %FINANCIAL_DATA = (
    "forex_trading_experience"             => "Over 3 years",
    "forex_trading_frequency"              => "0-5 transactions in the past 12 months",
    "binary_options_trading_experience"    => "1-2 years",
    "binary_options_trading_frequency"     => "40 transactions or more in the past 12 months",
    "cfd_trading_experience"               => "1-2 years",
    "cfd_trading_frequency"                => "0-5 transactions in the past 12 months",
    "other_instruments_trading_experience" => "Over 3 years",
    "other_instruments_trading_frequency"  => "6-10 transactions in the past 12 months",
    "employment_industry"                  => "Finance",
    "education_level"                      => "Secondary",
    "income_source"                        => "Self-Employed",
    "net_income"                           => '$25,000 - $50,000',
    "estimated_worth"                      => '$100,000 - $250,000',
    "account_turnover"                     => '$25,000 - $50,000',
    "occupation"                           => 'Managers',
    "employment_status"                    => "Self-Employed",
    "source_of_wealth"                     => "Company Ownership",
);
