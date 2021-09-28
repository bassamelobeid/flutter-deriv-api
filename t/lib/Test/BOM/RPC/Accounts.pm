package Test::BOM::RPC::Accounts;
use strict;
use warnings;
# %ACCOUNTS and %DETAILS are shared between four files, and should be kept in-sync to avoid test failures
#   t/BOM/RPC/MT5
#   t/BOM/RPC/05_accounts.t
#   t/BOM/RPC/Cashier/20_transfer_between_accounts.t
#   t/lib/mock_binary_mt5.pl

our %MT5_ACCOUNTS = (
    'demo\p01_ts01\financial\svg_std_usd'            => '1001001',
    'demo\p01_ts01\financial\svg_std-lim_usd'        => '1002101',
    'demo\p01_ts01\financial\svg_stp_usd'            => '1001002',
    'demo\p01_ts01\financial\labuan_std_usd'         => '1001003',
    'demo\p01_ts01\financial\labuan_stp_usd'         => '1001004',
    'demo\p01_ts01\synthetic\svg_std_usd'            => '1001005',
    'demo\p01_ts01\financial\maltainvest_std_gbp'    => '1001006',
    'demo\p01_ts01\financial\maltainvest_std_eur'    => '1001007',
    'real\p01_ts01\synthetic\malta_std_eur'          => '1001010',
    'real\p01_ts01\financial\maltainvest_std-hr_eur' => '1001011',
    'real\p01_ts01\financial\maltainvest_std-hr_usd' => '1001017',
    'real\p01_ts01\financial\maltainvest_std-hr_gbp' => '1001012',
    'real\p01_ts01\synthetic\svg_std_usd\01'         => '1001013',
    'real\p01_ts01\synthetic\svg_std_usd\02'         => '1001013',
    'real\p01_ts01\synthetic\svg_std_usd\03'         => '1001013',
    'real\p01_ts01\synthetic\svg_std_usd\04'         => '1001013',
    'real\p01_ts01\financial\svg_std-hr_usd'         => '1001014',
    'real\p01_ts01\financial\labuan_stp_usd'         => '1001015',
    'real\p01_ts01\financial\svg_std_usd'            => '1001016',
    'real\p01_ts01\financial\svg_std-lim_usd'        => '1002016',
    'real\p01_ts01\synthetic\malta_std_eur'          => '1001000',
    'real\p01_ts01\inactive_accounts_financial'      => '1002001',
    'real\p01_ts01\financial\svg_sf_usd'             => '21000002',
    'real\p01_ts02\synthetic\svg_std_usd\01'         => '21000001',
    'real\p01_ts02\synthetic\svg_std_usd\02'         => '21000001',
    'real\p01_ts02\synthetic\svg_std_usd\03'         => '21000001',
    'real\p01_ts02\synthetic\svg_std_usd\04'         => '21000001',
    'real\p01_ts02\synthetic\svg_sf_usd'             => '21000003',
    'real\p01_ts02\synthetic\svg_std-hr_usd'         => '21000004',
    # real03 account
    'real\p01_ts03\synthetic\svg_std_usd\01' => '41000001',
    'real\p01_ts03\synthetic\svg_std_usd\02' => '41000001',
    'real\p01_ts03\synthetic\svg_std_usd\03' => '41000001',
    'real\p01_ts03\synthetic\svg_std_usd\04' => '41000001',
    # real04 account
    'real\p01_ts04\synthetic\svg_std_usd\01' => '61000001',
    'real\p01_ts04\synthetic\svg_std_usd\02' => '61000001',
    'real\p01_ts04\synthetic\svg_std_usd\03' => '61000001',
    'real\p01_ts04\synthetic\svg_std_usd\04' => '61000001',
);

our $ADD_INACTIVE_ACCOUNT = 0;

our %MT5_GROUP_MAPPING = (
    'real\p01_ts01\financial\svg_std_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real\p01_ts01\financial\svg_std-hr_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    });

our %ACCOUNT_DETAILS = (
    password => {
        main     => 'Efgh4567',
        investor => 'Abcd1234',
    },
    email           => 'test.account@binary.com',
    name            => 'Meta traderman',
    group           => 'real\p01_ts01\synthetic\svg_std_usd',
    country         => 'Malta',
    balance         => '1234',
    display_balance => '1234.00',
    rights          => 16739,
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

