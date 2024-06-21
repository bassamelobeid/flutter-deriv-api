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
    'demo\p01_ts02\synthetic\svg_std_usd'            => '1001008',
    'demo\p01_ts02\financial\svg_std_usd'            => '1001009',
    'demo\p01_ts01\financial\bvi_std_usd'            => '1010001',
    'demo\po1_ts02\financial\bvi_std_usd'            => '1010002',
    'demo\p01_ts03\financial\svg_std_usd'            => '1001019',
    'demo\p01_ts01\synthetic\bvi_std_usd'            => '1010003',
    'demo\p01_ts02\synthetic\bvi_std_usd'            => '1001005',
    'demo\p01_ts03\synthetic\svg_std_usd'            => '1001018',
    'demo\p01_ts03\all\svg_std-sf_usd'               => '1001019',
    'real\p01_ts01\synthetic\malta_std_eur'          => '1001010',
    'real\p01_ts01\financial\maltainvest_std-hr_eur' => '1001011',
    'real\p01_ts01\financial\maltainvest_std-hr_usd' => '1001017',
    'real\p01_ts01\financial\maltainvest_std-hr_gbp' => '1001012',
    'real\p01_ts01\synthetic\svg_std_usd\01'         => '1001013',
    'real\p01_ts01\synthetic\svg_std_usd\02'         => '1001013',
    'real\p01_ts01\synthetic\svg_std_usd\03'         => '1001013',
    'real\p01_ts01\synthetic\svg_std_usd\04'         => '1001013',
    'real\p01_ts01\financial\svg_std-hr_usd'         => '1001014',
    'real\p01_ts01\financial\bvi_std-hr_usd'         => '1001019',
    'real\p01_ts01\financial\labuan_stp_usd'         => '1001015',
    'real\p01_ts01\financial\vanuatu_std-hr_usd'     => '1001020',
    'real\p01_ts01\financial\svg_std_usd'            => '1001016',
    'real\p01_ts01\financial\bvi_std_usd'            => '1001018',
    'real\p01_ts01\synthetic\bvi_std_usd'            => '1010004',
    'real\p01_ts01\all\svg_std-sf_usd'               => '1010004',
    'real\p01_ts02\synthetic\bvi_std_usd'            => '1010005',
    'real\p01_ts03\synthetic\bvi_std_usd'            => '1010006',
    'real\p01_ts04\synthetic\bvi_std_usd'            => '1010007',
    'real\p02_ts02\synthetic\bvi_std_usd'            => '1010008',
    'real\p01_ts01\synthetic\bvi_std-hr_usd'         => '1010009',
    'real\p01_ts02\synthetic\bvi_std-hr_usd'         => '1010010',
    'real\p01_ts03\synthetic\bvi_std-hr_usd'         => '1010011',
    'real\p01_ts04\synthetic\bvi_std-hr_usd'         => '1010012',
    'real\p02_ts02\synthetic\bvi_std-hr_usd'         => '1010013',
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
    # seychelles
    'real\p02_ts02\synthetic\seychelles_ib_usd' => '999999',

    # real p02_ts01
    'real\p02_ts01\all\svg_std-sf_usd' => '80000020',

    # Zero spread real test account
    'real\p01_ts01\all\bvi_zs-hr_usd' => '1001021',
    'real\p01_ts01\all\bvi_zs_usd'    => '1001022',
    'real\p02_ts01\all\bvi_zs-hr_usd' => '80000001',
    'real\p02_ts01\all\bvi_zs_usd'    => '80000002',

    # Zero spread demo test account
    'demo\p01_ts01\all\bvi_zs_usd' => '1010015',
    'demo\p01_ts02\all\bvi_zs_usd' => '20100001',
    'demo\p01_ts03\all\bvi_zs_usd' => '30100001',
    'demo\p01_ts04\all\bvi_zs_usd' => '40100001',
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
        main     => 'Efgh4567@',
        investor => 'Abcd1234@',
    },
    email           => 'test.account@binary.com',
    name            => 'Meta traderman',
    group           => 'real\p01_ts01\synthetic\svg_std_usd',
    country         => 'Malta',
    balance         => 1234,
    display_balance => '1234.00',
    phone           => '+1 234 56789',
    zipCode         => '111111',
    address         => 'some address',
    phonePassword   => 'XXXXXX',
    state           => 'CA',
    city            => 'San Andreas :)',
    company         => 'my company',
    leverage        => 300,
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

our %FINANCIAL_DATA_MF = (
    "risk_tolerance"                           => "Yes",
    "source_of_experience"                     => "I have an academic degree, professional certification, and/or work experience.",
    "cfd_experience"                           => "Less than a year",
    "cfd_frequency"                            => "1 - 5 transactions in the past 12 months",
    "trading_experience_financial_instruments" => "Less than a year",
    "trading_frequency_financial_instruments"  => "1 - 5 transactions in the past 12 months",
    "cfd_trading_definition"                   => "Speculate on the price movement.",
    "leverage_impact_trading"                  => "Leverage lets you open larger positions for a fraction of the trade's value.",
    "leverage_trading_high_risk_stop_loss"     => "Close your trade automatically when the loss is more than or equal to a specific amount.",
    "required_initial_margin"                  => "When opening a Leveraged CFD trade.",
    "employment_industry"                      => "Finance",
    "education_level"                          => "Secondary",
    "income_source"                            => "Self-Employed",
    "net_income"                               => '$25,000 - $50,000',
    "estimated_worth"                          => '$100,000 - $250,000',
    "account_turnover"                         => '$25,000 - $50,000',
    "occupation"                               => 'Managers',
    "employment_status"                        => "Self-Employed",
    "source_of_wealth"                         => "Company Ownership",
);

our $proxy_user_deposit_change_json = '{"user":{"ticket":4010001269},"ret_code":0}';

our %proxy_user_get_json = (
    'real\p01_ts01\financial\vanuatu_std-hr_usd' =>
        '{"user":{"name":"Meta traderman","leverage":500,"balance":"0.00","email":"test.account@binary.com","group":"real\\\\p01_ts01\\\\financial\\\\vanuatu_std-hr_usd","rights":485,"login":1001020,"color":4278190080,"country":"Indonesia"},"ret_code":0}',
);

our %proxy_group_get_json = (
    'real\p01_ts01\financial\vanuatu_std-hr_usd' =>
        '{"group":{"group":"real\\\\p01_ts01\\\\financial\\\\vanuatu_std-hr_usd","leverage":500,"company":"Deriv Limited","currency":"USD"},"ret_code":0}',
);
