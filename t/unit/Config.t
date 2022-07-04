use strict;
use warnings;
use Test::More;
use Test::Deep;
use Array::Utils qw(array_minus);
use Scalar::Util qw(refaddr);
use BOM::Config;

my $test_parameters = [{
        name => 'node.yml',
        args => {
            expected_config => {
                node => {
                    environment      => 'some_env',
                    operation_domain => 'some_domain',
                    roles            => ['some_role'],
                    tags             => ['some_tag']
                },
                feed_server        => {fqdn => '0.0.0.0'},
                local_redis_master => ''
            },
            config     => \&BOM::Config::node,
            array_test => ["node:roles", "node:tags"]    #Optional key. Tests specifed path for array ref values.
        }
    },
    {
        name => 'aes_keys.yml',
        args => {
            expected_config => {
                client_secret_answer => {
                    default_keynum => 1,
                    1              => ''
                },
                client_secret_iv => {
                    default_keynum => 1,
                    1              => ''
                },
                email_verification_token => {
                    default_keynum => 1,
                    1              => ''
                },
                password_counter => {
                    default_keynum => 1,
                    1              => ''
                },
                password_remote => {
                    default_keynum => 1,
                    1              => ''
                },
                payment_agent => {
                    default_keynum => 1,
                    1              => ''
                },
                feeds => {
                    default_keynum => 1,
                    1              => ''
                },
                web_secret => {
                    default_keynum => 1,
                    1              => ''
                }
            },
            config => \&BOM::Config::aes_keys,

        }
    },
    {
        name => 'third_party.yml',
        args => {
            expected_config => {
                auth0 => {
                    client_id     => '',
                    client_secret => '',
                    api_uri       => ''
                },
                duosecurity => {
                    ikey => '',
                    skey => '',
                    akey => ''
                },
                doughflow => {
                    binary      => '',
                    deriv       => '',
                    champion    => '',
                    passcode    => '',
                    environment => ''
                },
                myaffiliates => {
                    user                  => '',
                    pass                  => '',
                    host                  => '',
                    aws_access_key_id     => '',
                    aws_secret_access_key => '',
                    aws_bucket            => '',
                    aws_region            => ''
                },
                oneall => {
                    binary => {
                        public_key  => '',
                        private_key => ''
                    },
                    deriv => {
                        public_key  => '',
                        private_key => ''
                    }
                },
                proveid => {
                    username     => '',
                    password     => '',
                    pdf_username => '',
                    pdf_password => '',
                    public_key   => '',
                    private_key  => '',
                    api_uri      => '',
                    api_proxy    => '',
                    experian_url => '',
                    uat          => {
                        username    => '',
                        password    => '',
                        public_key  => '',
                        private_key => ''
                    }
                },
                bloomberg => {
                    sftp_allowed => '',
                    user         => '',
                    password     => '',
                    aws          => {
                        upload_allowed => '',
                        path           => '',
                        bucket         => '',
                        profile        => '',
                        log            => ''
                    }
                },
                qa_duosecurity => {
                    ikey => '',
                    skey => ''
                },
                gamstop => {
                    api_uri   => '',
                    batch_uri => '',
                    config    => {
                        iom   => {api_key => ''},
                        malta => {api_key => ''}}
                },
                elevio     => {account_secret => ''},
                customerio => {
                    site_id   => '',
                    api_key   => '',
                    api_token => '',
                    api_uri   => ''
                },
                onfido => {
                    authorization_token => '',
                    webhook_token       => ''
                },
                smartystreets => {
                    auth_id  => '',
                    token    => '',
                    licenses => {
                        basic => '',
                        plus  => ''
                    },
                    countries => {plus => []}
                },
                segment => {
                    write_key => '',
                    base_uri  => ''
                },
                rudderstack => {
                    write_key => '',
                    base_uri  => ''
                },
                sendbird => {
                    app_id    => '',
                    api_token => ''
                },
                eu_sanctions => {token => ''},
                banxa        => {
                    api_url    => '',
                    api_key    => '',
                    api_secret => ''
                },
                wyre => {
                    api_url        => '',
                    api_account_id => '',
                    api_secret     => ''
                },
                acquired       => {company_hashcode   => ''},
                isignthis      => {notification_token => 'some env'},
                smile_identity => {
                    api_url    => '',
                    partner_id => '',
                    api_key    => ''
                },
                zaig => {
                    api_url => '',
                    api_key => ''
                },
                close_io => {
                    api_url => '',
                    api_key => ''
                },
                risk_screen => {
                    api_url => '',
                    api_key => '',
                    port    => ''
                },
                cellxperts => {base_uri => 'some env'}
            },
            config     => \&BOM::Config::third_party,
            array_test => ["smartystreets:countries:plus"]
        }
    },
    {
        name => 'randsrv.yml',
        args => {
            expected_config => {
                rand_server => {
                    fqdn => '',
                    port => '',
                    password => ''
                }
            },
            config => \&BOM::Config::randsrv
        }
    },
    {
        name => 'backoffice.yml',
        args => {
            expected_config => {
                directory => {
                    tmp_gif => '',
                    tmp => ''
                },
                log => {
                    deposit => '',
                    withdraw_broker => '',
                    staff => '',
                    staff_dir => '',
                    fsave_complete => ''
                },
                experian_document_s3 => {
                    aws_bucket => '',
                    aws_region => '',
                    aws_access_key_id => '',
                    aws_secret_access_key => ''
                }
            },
            config => \&BOM::Config::backoffice
        }
    },
    {
        name => 'currency_config.yml',
        args => {
            expected_config => {
                currency_pairs => []
            },
            config => \&BOM::Config::currency_pairs_backoffice
        }
    },
    {
        name => 'paymentagent_config.yml',
        args => {
            expected_config => {
                payment_limits => {
                    fiat => {
                        minimum => '',
                        maximum => ''
                    },
                    crypto => {
                        minimum => '',
                        maximum => ''
                    }
                },
                currency_specific_limits => {
                    BUSD => {
                        minimum => '',
                        maximum => ''
                    },
                    DAI => {
                        minimum => '',
                        maximum => ''
                    },
                    EURS => {
                        minimum => '',
                        maximum => ''
                    },
                    PAX => {
                        minimum => '',
                        maximum => ''
                    },
                    TUSD => {
                        minimum => '',
                        maximum => ''
                    },
                    USDC => {
                        minimum => '',
                        maximum => ''
                    },
                    USDK => {
                        minimum => '',
                        maximum => ''
                    },
                    UST => {
                        minimum => '',
                        maximum => ''
                    },
                    eUSDT => {
                        minimum => '',
                        maximum => ''
                    }
                },
                minimum_topup_balance => {
                    DEFAULT => ''
                },
                transaction_limits => {
                    transfer => {
                        transactions_per_day => '',
                        amount_in_usd_per_day => ''
                    },
                    withdraw => {
                        weekday => {
                            transactions_per_day => '',
                            amount_in_usd_per_day => ''
                        },
                        weekend => {
                            transactions_per_day => '',
                            amount_in_usd_per_day => ''
                        }
                    }
                }
            },
            config => \&BOM::Config::payment_agent
        }
    },
    {
        name => 'payment_limits.yml',
        args => {
            expected_config => {
                withdrawal_limits => {
                    iom => {
                        for_days => '',
                        currency => '',
                        limit_for_days => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''
                    },
                    malta => {
                        for_days => '',
                        currency => '',
                        limit_for_days => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''
                    },
                    maltainvest => {
                        for_days => '',
                        currency => '',
                        limit_for_days => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''                       
                    },
                    svg => {
                        for_days => '',
                        currency => '',
                        limit_for_days => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''
                    },
                    "wallet-svg" => {
                        for_days => '',
                        currency => '',
                        limit_for_days => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''
                    },
                    champion => {
                        for_days => '',
                        currency => '',
                        limit_for_days => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''
                    },
                    samoa => {
                        for_days => '',
                        currency => '',
                        limit_for_days => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''
                    }
                },
                qualifying_payment_check_limits => {
                    iom => {
                        for_days => '',
                        currency => '',
                        limit_for_days => ''
                    }
                }
            },
            config => \&BOM::Config::payment_limits
        }
    },
    {
        name => 'client_limts.yml',
        args => {
            expected_config => {
                maximum_daily_turnover => {
                    USD => '',
                    EUR => '',
                    AUD => '',
                    GBP => '',
                    BTC => '',
                    ETH => '',
                    LTC => '',
                    BUSD => '',
                    DAI => '',
                    EURS => '',
                    IDK => '',
                    PAX => '',
                    TUSD => '',
                    USB => '',
                    USDC => '',
                    USDK => '',
                    UST => '',
                    eUSDT => ''
                },
                max_balance => {
                    virtual => {
                        USD => '',
                        EUR => '',
                        AUD => '',
                        GBP => '',
                        BTC => '',
                        ETH => '',
                        LTC => '',
                        BUSD => '',
                        DAI => '',
                        EURS => '',
                        IDK => '',
                        PAX => '',
                        TUSD => '',
                        USB => '',
                        USDC => '',
                        USDK => '',
                        UST => '',
                        eUSDT => ''
                    },
                    real => {
                        USD => '',
                        EUR => '',
                        AUD => '',
                        GBP => '',
                        BTC => '',
                        ETH => '',
                        LTC => '',
                        BUSD => '',
                        DAI => '',
                        EURS => '',
                        IDK => '',
                        PAX => '',
                        TUSD => '',
                        USB => '',
                        USDC => '',
                        USDK => '',
                        UST => '',
                        eUSDT => ''
                    }
                },
                max_payout_open_positions => {
                    USD => '',
                    EUR => '',
                    AUD => '',
                    GBP => '',
                    BTC => '',
                    ETH => '',
                    LTC => '',
                    BUSD => '',
                    DAI => '',
                    EURS => '',
                    IDK => '',
                    PAX => '',
                    TUSD => '',
                    USB => '',
                    USDC => '',
                    USDK => '',
                    UST => '',
                    eUSDT => ''
                },
                max_open_bets_default => '',
                max_payment_accounts_per_user => '',
                max_client_payment_accounts_per_broker_code => {
                    MF => '',
                    MLT => '',
                    MX => ''
                }
            },
            config => \&BOM::Config::client_limits
        }
    },
    {
        name => 'cryptocurrency_api.yml',
        args => {
            expected_config => {
                host => '',
                port => ''
            },
            config => \&BOM::Config::crypto_api
        }
    },
    {
        name => 'domain.yml',
        args => {
            expected_config => {
                default_domain => '',
                white_list => [],
                brand => ''
            },
            config => \&BOM::Config::domain,
            array_test => ["white_list"],
        }
    },
    {
        name => 's3.yml',
        args => {
            expected_config => {
                document_auth => {
                    aws_bucket => '',
                    aws_region => '',
                    aws_access_key_id => '',
                    aws_secret_access_key => ''
                },
                desk => {
                    aws_bucket => '',
                    aws_region => '',
                    aws_access_key_id => '',
                    aws_secret_access_key => ''
                }
            },
            config => \&BOM::Config::s3
        }
    },
    {
        name => 'feed_rpc.yml',
        args => {
            expected_config => {
                writer => {
                    feeddb_uri => ''
                }
            },
            config => \&BOM::Config::feed_rpc
        }
    },
    {
        name => 'financial_assessment_structure.yml',
        args => {
            expected_config => {
                trading_experience => {
                    forex_trading_experience => {
                        label => '',
                        possible_answer => {
                            '0-1 year' => '',
                            '1-2 years' => '',
                            'Over 3 years' => ''
                        }
                    },
                    forex_trading_frequency => {
                        label => '',
                        possible_answer => {
                            '0-5 transactions in the past 12 months' => '',
                            '6-10 transactions in the past 12 months' => '',
                            '11-39 transactions in the past 12 months' => '',
                            '40 transactions or more in the past 12 months' => ''
                        }
                    },
                    binary_options_trading_experience => {
                        label => '',
                        possible_answer => {
                            '0-1 year' => '',
                            '1-2 years' => '',
                            'Over 3 years' => ''
                        }
                    },
                    binary_options_trading_frequency => {
                        label => '',
                        possible_answer => {
                            '0-5 transactions in the past 12 months' => '',
                            '6-10 transactions in the past 12 months' => '',
                            '11-39 transactions in the past 12 months' => '',
                            '40 transactions or more in the past 12 months' => ''
                        }
                    },
                    cfd_trading_experience => {
                        label => '',
                        possible_answer => {
                            '0-1 year' => '',
                            '1-2 years' => '',
                            'Over 3 years' => ''
                        }
                    },
                    cfd_trading_frequency => {
                        label => '',
                        possible_answer => {
                            '0-5 transactions in the past 12 months' => '',
                            '6-10 transactions in the past 12 months' => '',
                            '11-39 transactions in the past 12 months' => '',
                            '40 transactions or more in the past 12 months' => ''
                        }
                    },
                    other_instruments_trading_experience => {
                        label => '',
                        possible_answer => {
                            '0-1 year' => '',
                            '1-2 years' => '',
                            'Over 3 years' => ''
                        }
                    },
                    other_instruments_trading_frequency => {
                        label => '',
                        possible_answer => {
                            '0-5 transactions in the past 12 months' => '',
                           '6-10 transactions in the past 12 months' => '',
                            '11-39 transactions in the past 12 months' => '',
                            '40 transactions or more in the past 12 months' => ''
                        }
                    }
                },
                financial_information => {
                    employment_industry => {
                        label => '',
                        possible_answer => {
                            'Construction' => 0,
                            'Education' => 0,
                            'Finance' => 0,
                            'Health' => 0,
                            'Tourism' => 0,
                            'Information & Communications Technology' => 0,
                            'Science & Engineering' => 0,
                            'Legal' => 0,
                            'Social & Cultural' => 0,
                            'Agriculture' => 0,
                            'Real Estate' => 0,
                            'Food Services' => 0,
                            'Manufacturing' => 0,
                            'Unemployed' => 0,
                        }
                    },
                    education_level => {
                        label => '',
                        possible_answer => {
                            'Primary' => 0,
                            'Secondary' => 0,
                            'Tertiary' => 0,
                        }
                    },
                    income_source => {
                        label => '',
                        possible_answer => {
                            'Salaried Employee' => 0,
                            'Self-Employed' => 0,
                            'Investments & Dividends' => 0,
                            'Pension' => 0,
                            'State Benefits' => 0,
                            'Savings & Inheritance' => 0
                        }
                    },
                    net_income => {
                        label => '',
                        possible_answer => {
                            'Less than $25,000' => 0,
                            '$25,000 - $50,000' => 0,
                            '$50,001 - $100,000' => 0,
                            '$100,001 - $500,000' => 0,
                            'Over $500,000' => 0,
                        }
                    },
                    estimated_worth => {
                        label => '',
                        possible_answer => {
                            'Less than $100,000' => 0,
                            '$100,000 - $250,000' => 0,
                            '$250,001 - $500,000' => 0,
                            '$500,001 - $1,000,000'=> 0,
                            'Over $1,000,000' => 0,
                        }
                    },
                    account_turnover => {
                        label => '',
                        possible_answer => {
                            'Less than $25,000' => 0,
                            '$25,000 - $50,000' => 0,
                            '$50,001 - $100,000' => 0,
                            '$100,001 - $500,000' => 0,
                            'Over $500,000' => 0,
                        }
                    },
                    occupation => {
                        label => '',
                        possible_answer => {
                            'Chief Executives, Senior Officials and Legislators'=> 0,
                            'Managers'=> 0,
                            'Professionals'=> 0,
                            'Clerks' => 0,
                            'Personal Care, Sales and Service Workers' => 0,
                            'Agricultural, Forestry and Fishery Workers' => 0,
                            'Craft, Metal, Electrical and Electronics Workers' => 0,
                            'Plant and Machine Operators and Assemblers' => 0,
                            'Cleaners and Helpers' => 0,
                            'Mining, Construction, Manufacturing and Transport Workers' => 0,
                            'Armed Forces' => 0,
                            'Government Officers' => 0,
                            'Students' => 0,
                            'Unemployed' => 0,
                        }
                    },
                    employment_status => {
                        label => '',
                        possible_answer => {
                            'Employed' => '',
                            'Pensioner' => '',
                            'Self-Employed' => '',
                            'Student' => '',
                            'Unemployed' => ''
                        }
                    },
                    source_of_wealth => {
                        label => '',
                        possible_answer => {
                            'Accumulation of Income/Savings' => '',
                            'Cash Business' => '',
                            'Company Ownership' => '',
                            'Divorce Settlement' => '',
                            'Inheritance' => '',
                            'Investment Income' => '',
                            'Sale of Property' => ''
                        }
                    }
                }
            },
            config => \&BOM::Config::financial_assessment_fields
        }
    },
    {
        name => 'social_responsibility_thresholds.yml',
        args => {
            expected_config => {
                limits => [
                    {
                        losses => '',
                        net_deposits => '',
                        net_income => '',
                        hello => ''
                    }
                ]
            },
            config => \&BOM::Config::social_responsibility_thresholds,
            array_test => ["limits"]
        }
    },
    {
        name => 'p2p_payment_methods.yml',
        args => {
            expected_config => {
                '2checkout' => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                '543konse' => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                access_money_wallet => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                airtel => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                alipay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                apple_pay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                atease => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                azimo => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                bank_transfer => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        },
                        bank_code => {
                            display_name => '',
                            required => 0
                        },
                        bank_name => {
                            display_name => ''
                        },
                        branch => {
                            display_name => '',
                            required => ''
                        }
                    },
                    type => ''
                },
                bitpay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                boss_revolution => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                broadpay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                btc_smega => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                buyonline => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                carbon => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                cashenvoy => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                cassava_remit => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                cellulant => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                celpaid => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                clicknpay_africa => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                clickpesa => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                dpo => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                dusupay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                ecobank_mobilemoney => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                ecocash => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                equitel => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                etranzact => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                ewallet_services_tanzania => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                exchange4free => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                firstmonie => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                flutterwave => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                fnb => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                fortis => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                gcb => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                glo => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                google_pay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                gt_pay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                halotel => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                hubtel => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                instacash => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                inter_pay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                ipay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                kazang => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                konga => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                mascom_my_zaka => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                mlipa => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                mnaira => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                mobicash => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                mobipay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                moov => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                mpesa_tanzania => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                mtn_momo => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                myghpay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                netpay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                nettcash => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                noqodi => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                nownow => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                onemoney => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                opay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                orange_money => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                other => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => '',
                            required => 0
                        },
                        name => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                paga => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                palmpay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                paxful => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                payant => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                paygate => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                paynow => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                paypal => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                payserv => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                paystack => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                paytoday => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                pesapel => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                pocketmoni => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                posomoney => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                postdotnet => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                qash => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                qless => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                quickteller => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                realpay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                rocket_remit => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                safaricom_mpesa => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                simplepay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                skrill => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                solidpaywave => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                speedpay_mobile => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                sticpay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                stripe => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                talkremit => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                tangaza_pesa => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                teasy_mobile_money => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                teasy_mobile_money => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                telecash => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                terrapay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                tigo_pesa => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                tilt_africa => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                transferwise => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                united_bank_of_zambia_ewallet => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                unitylink => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                vcash => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                vodafone_cash => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                voguepay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                wari => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                wave_mobile_money => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                webmoney => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                wechat_pay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                xapit_zanaco => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                xendpay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                xoom => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                xpress_money => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                yucash => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                yup_africa => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                zamlink => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                zamtel => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                zantel => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                zazu => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                zim_switch => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                zimpayments => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                zoona => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                zotapay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                },
                zympay => {
                    display_name => '',
                    fields => {
                        account => {
                            display_name => ''
                        }
                    },
                    type => ''
                }
            },
            config => \&BOM::Config::p2p_payment_methods
        }
    },
    {
        name => 'cft_blocked_countries.yml',
        args => {
            expected_config => {
                bd => {
                    display_name => ''
                },
                io => {
                    display_name => ''
                },
                kh => {
                    display_name => ''
                },
                ca => {
                    display_name => ''
                },
                co => {
                    display_name => ''
                },
                hk => {
                    display_name => ''
                },
                id => {
                    display_name => ''
                },
                il => {
                    display_name => ''
                },
                jp => {
                    display_name => ''
                },
                ls => {
                    display_name => ''
                },
                mo => {
                    display_name => ''
                },
                my => {
                    display_name => ''
                },
                np => {
                    display_name => ''
                },
                nl => {
                    display_name => ''
                },
                nz => {
                    display_name => ''
                },
                pk => {
                    display_name => ''
                },
                ph => {
                    display_name => ''
                },
                sg => {
                    display_name => ''
                },
                za => {
                    display_name => ''
                },
                kr => {
                    display_name => ''
                },
                lk => {
                    display_name => ''
                },
                ch => {
                    display_name => ''
                },
                th => {
                    display_name => ''
                },
                tr => {
                    display_name => ''
                },
                us => {
                    display_name => ''
                },
                um => {
                    display_name => ''
                },
                ve => {
                    display_name => ''
                },
                vn => {
                    display_name => ''
                },
                vi => {
                    display_name => ''
                }
            },
            config => \&BOM::Config::cft_blocked_countries
        }
    },
    {
        name => 'cashier.yml',
        args => {
            expected_config => {
                doughflow => {
                    sportsbooks_mapping => {
                        svg => '',
                        malta => '',
                        iom => '',
                        maltainvest => '',
                        samoa => '',
                        dsl => ''
                    }
                }
            },
            config => \&BOM::Config::cashier_config
        }
    },
    {
        name => 'redis-replicated.yml',
        args => {
            expected_config => {
                write => {
                    host => '',
                    port => '',
                    password => ''
                },
                read => {
                    host => '',
                    port => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_replicated_config
        }
    },
    {
        name => 'redis-pricer.yml',
        args => {
            expected_config => {
                write => {
                    host => '',
                    port => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_pricer_config
        }
    },
    {
        name => 'redis-pricer-subscription.yml',
        args => {
            expected_config => {
                write => {
                    host => '',
                    port => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_pricer_subscription_config
        }
    },
    {
        name => 'redis-pricer-shared.yml',
        args => {
            expected_config => {
                write => {
                    host => '',
                    port => '',
                    password => ''
                },
                read => {
                    host => '',
                    port => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_pricer_shared_config
        }
    },
    {
        name => 'redis-exchangerates.yml',
        args => {
            expected_config => {
                write => {
                    host => '',
                    port => '',
                    password => ''
                },
                read => {
                    host => '',
                    port => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_exchangerates_config
        }
    },
    {
        name => 'redis-feed.yml',
        args => {
            expected_config => {
                'master-write' => {
                    host => '',
                    port => '',
                    password => ''
                },
                'master-read' => {
                    host => '',
                    port => '',
                    password => ''
                },
                write => {
                    host => '',
                    port => '',
                    password => ''
                },
                read => {
                    host => '',
                    port => '',
                    password => ''
                },
                'fake-read' => {
                    host => '',
                    port => '',
                    password => ''
                },
                'local' => {
                    host => '',
                    port => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_feed_config
        }
    },
    {
        name => 'redis-mt5user.yml',
        args => {
            expected_config => {
                write => {
                    host => '',
                    port => '',
                    password => ''
                },
                read => {
                    host => '',
                    port => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_mt5_user_config
        }
    }
    ];

for my $test_parameter (@$test_parameters) {
    subtest "Test YAML return correct structure for $test_parameter->{name}", \&yaml_structure_validator, $test_parameter->{args};
}


sub yaml_structure_validator {
    my $args            = shift;
    my $expected_config = $args->{expected_config};
    my $config          = $args->{config}->();
    my @received_keys   = ();
    _get_all_paths(
        $config,
        sub {
            push @received_keys, join("|", @_);
        });
    my @expected_keys = ();
    _get_all_paths(
        $expected_config,
        sub {
            push @expected_keys, join("|", @_);
        });
    my @differences_keys = array_minus(@expected_keys, @received_keys);
    if(  scalar @differences_keys != 0){
        diag("\n");
        diag(@differences_keys);
    }
    is(scalar @differences_keys, 0, 'BOM::Config::node returns correct structure');
    yaml_array_sub_structure_validator($config, $args->{array_test}) if exists($args->{array_test});
}

sub yaml_array_sub_structure_validator {
    my $config      = shift;
    my $array_paths = shift;
    for my $path (@$array_paths) {
        my @keys = split(':', $path);
        my $val  = $config;
        for my $key (@keys) {
            $val = $val->{$key};
        }
        is(ref $val, 'ARRAY', $keys[-1] . " is an array");
    }
}

sub _get_all_paths {
    my ($hashref, $code, $args) = @_;
    while (my ($k, $v) = each(%$hashref)) {
        my @newargs = defined($args) ? @$args : ();
        push(@newargs, $k);
        if (ref($v) eq 'HASH') {
            _get_all_paths($v, $code, \@newargs);
        } else {
            $code->(@newargs);
        }
    }
}

done_testing;
