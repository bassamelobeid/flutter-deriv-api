package Test::BOM::RPC::Accounts;
use strict;
use warnings;
# %ACCOUNTS and %DETAILS are shared between four files, and should be kept in-sync to avoid test failures
#   t/BOM/RPC/MT5
#   t/BOM/RPC/05_accounts.t
#   t/BOM/RPC/Cashier/20_transfer_between_accounts.t
#   t/lib/mock_binary_mt5.pl

our %MT5_ACCOUNTS = (
    'demo\svg_financial'               => '00001001',
    'demo\svg_financial_stp'           => '00001002',
    'demo\labuan_financial'            => '00001003',
    'demo\labuan_financial_stp'        => '00001004',
    'real\malta'                       => '00001010',
    'real\maltainvest_financial'       => '00001011',
    'real\maltainvest_financial_GBP'   => '00001012',
    'real\svg'                         => '00001013',
    'real\svg_financial'               => '00001014',
    'real\labuan_financial_stp'        => '00001015',
    'real\svg_financial_Bbook'         => '00001016',
    'real01\synthetic\svg_std_usd'     => '00001017',
    'real\inactive_accounts_financial' => '00002001',
);

our $ADD_INACTIVE_ACCOUNT = 0;

our %MT5_GROUP_MAPPING = (
    'real\svg_financial_Bbook' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real\svg_financial' => {
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
    group           => 'real\svg',
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

our %EXPECTED_MT5_GROUP_MAPPINGS = (
    'real01\synthetic\svg_std_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'real02\synthetic\svg_std_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'real01\synthetic\svg_std-hr_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'real02\synthetic\svg_std-hr_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'real01\synthetic\svg_sf_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'swap_free'
    },
    'real02\synthetic\svg_sf_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'swap_free'
    },
    'real01\synthetic\svg_sf-hr_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'swap_free'
    },
    'real02\synthetic\svg_sf-hr_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'swap_free'
    },
    'real01\synthetic\malta_std_eur' => {
        'account_type'          => 'real',
        'landing_company_short' => 'malta',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'real02\synthetic\malta_std_eur' => {
        'account_type'          => 'real',
        'landing_company_short' => 'malta',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'real01\synthetic\malta_sf_eur' => {
        'account_type'          => 'real',
        'landing_company_short' => 'malta',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'swap_free'
    },
    'real02\synthetic\malta_sf_eur' => {
        'account_type'          => 'real',
        'landing_company_short' => 'malta',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'swap_free'
    },
    'real01\synthetic\samoa_std_btc' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'real02\synthetic\samoa_std_btc' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'real01\synthetic\samoa_std_ust' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'real02\synthetic\samoa_std_ust' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'real01\financial\labuan_stp_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'labuan',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial_stp'
    },
    'real02\financial\labuan_stp_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'labuan',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial_stp'
    },
    'real01\financial\bvi_stp_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'bvi',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial_stp'
    },
    'real02\financial\bvi_stp_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'bvi',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial_stp'
    },
    'real01\financial\maltainvest_std-hr_eur' => {
        'account_type'          => 'real',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real02\financial\maltainvest_std-hr_eur' => {
        'account_type'          => 'real',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real01\financial\maltainvest_sf-hr_eur' => {
        'account_type'          => 'real',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real02\financial\maltainvest_sf-hr_eur' => {
        'account_type'          => 'real',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real01\financial\maltainvest_std-hr_gbp' => {
        'account_type'          => 'real',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real02\financial\maltainvest_std-hr_gbp' => {
        'account_type'          => 'real',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real01\financial\maltainvest_sf-hr_gbp' => {
        'account_type'          => 'real',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real02\financial\maltainvest_sf-hr_gbp' => {
        'account_type'          => 'real',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real01\financial\vanuatu_std-hr_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'vanuatu',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real02\financial\vanuatu_std-hr_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'vanuatu',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real01\financial\svg_std_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real02\financial\svg_std_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real01\financial\svg_std-hr_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real02\financial\svg_std-hr_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real01\financial\svg_sf_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real02\financial\svg_sf_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real01\financial\svg_sf-hr_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real02\financial\svg_sf-hr_usd' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real01\financial\samoa_std-hr_btc' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real02\financial\samoa_std-hr_btc' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real01\financial\samoa_std_btc' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real02\financial\samoa_std_btc' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real01\financial\samoa_std-hr_ust' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real02\financial\samoa_std-hr_ust' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real01\financial\samoa_std_ust' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real02\financial\samoa_std_ust' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real01\financial\samoa_sf-hr_btc' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real02\financial\samoa_sf-hr_btc' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real01\financial\samoa_sf_btc' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real02\financial\samoa_sf_btc' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real01\financial\samoa_sf-hr_ust' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real02\financial\samoa_sf-hr_ust' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real01\financial\samoa_sf_ust' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'real02\financial\samoa_sf_ust' => {
        'account_type'          => 'real',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'demo\synthetic\svg_std_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'demo\synthetic\svg_sf_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'swap_free'
    },
    'demo\synthetic\malta_std_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'malta',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'demo\synthetic\malta_sf_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'malta',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'swap_free'
    },
    'demo\synthetic\samoa_std_btc' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'samoa',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'demo\synthetic\samoa_std_ust' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'samoa',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'demo\financial\labuan_stp_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'labuan',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial_stp'
    },
    'demo\financial\maltainvest_std_eur' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\financial\maltainvest_sf_eur' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'demo\financial\maltainvest_std_gbp' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\financial\maltainvest_sf_gbp' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'demo\financial\vanuatu_std_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'vanuatu',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\financial\svg_std_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\financial\svg_sf_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'demo\financial\samoa_std_btc' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\financial\samoa_std_ust' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\synthetic\svg_std_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'demo\synthetic\svg_sf_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'swap_free'
    },
    'demo\synthetic\malta_std_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'malta',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'demo\synthetic\malta_sf_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'malta',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'swap_free'
    },
    'demo\synthetic\samoa_std_btc' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'samoa',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'demo\synthetic\samoa_std_ust' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'samoa',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'demo\financial\labuan_stp_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'labuan',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial_stp'
    },
    'demo\financial\maltainvest_std_eur' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\financial\maltainvest_sf_eur' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'demo\financial\maltainvest_std_gbp' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\financial\maltainvest_sf_gbp' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'demo\financial\vanuatu_std_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'vanuatu',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\financial\svg_std_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\financial\svg_sf_usd' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'swap_free'
    },
    'demo\financial\samoa_std_btc' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\financial\samoa_std_ust' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'samoa',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real\svg' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'real\svg_highrisk' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'real\malta' => {
        'account_type'          => 'real',
        'landing_company_short' => 'malta',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'real\labuan_financial_stp' => {
        'account_type'          => 'real',
        'landing_company_short' => 'labuan',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial_stp'
    },
    'real\maltainvest_financial' => {
        'account_type'          => 'real',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real\maltainvest_financial_gbp' => {
        'account_type'          => 'real',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real\vanuatu_financial' => {
        'account_type'          => 'real',
        'landing_company_short' => 'vanuatu',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real\svg_financial_bbook' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'real\svg_financial' => {
        'account_type'          => 'real',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\svg' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'svg',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'demo\malta' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'malta',
        'market_type'           => 'gaming',
        'sub_account_type'      => 'financial'
    },
    'demo\labuan_financial_stp' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'labuan',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial_stp'
    },
    'demo\maltainvest_financial' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\maltainvest_financial_gbp' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'maltainvest',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\vanuatu_financial' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'vanuatu',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
    'demo\svg_financial' => {
        'account_type'          => 'demo',
        'landing_company_short' => 'svg',
        'market_type'           => 'financial',
        'sub_account_type'      => 'financial'
    },
);

