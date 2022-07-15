use strict;
use warnings;
use BOM::Config;
use Test::More;
use lib qw(/home/git/regentmarkets/bom-config/t/lib/);
use YamlTestStructure;

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
            array_test => ["smartystreets:countries:plus"]}
    },
    {
        name => 'randsrv.yml',
        args => {
            expected_config => {
                rand_server => {
                    fqdn     => '',
                    port     => '',
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
                    tmp     => ''
                },
                log => {
                    deposit         => '',
                    withdraw_broker => '',
                    staff           => '',
                    staff_dir       => '',
                    fsave_complete  => ''
                },
                experian_document_s3 => {
                    aws_bucket            => '',
                    aws_region            => '',
                    aws_access_key_id     => '',
                    aws_secret_access_key => ''
                }
            },
            config => \&BOM::Config::backoffice
        }
    },
    {
        name => 'currency_config.yml',
        args => {
            expected_config => {currency_pairs => []},
            config          => \&BOM::Config::currency_pairs_backoffice
        },
        array_test => ["currency_pairs"]
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
                minimum_topup_balance => {DEFAULT => ''},
                transaction_limits    => {
                    transfer => {
                        transactions_per_day  => '',
                        amount_in_usd_per_day => ''
                    },
                    withdraw => {
                        weekday => {
                            transactions_per_day  => '',
                            amount_in_usd_per_day => ''
                        },
                        weekend => {
                            transactions_per_day  => '',
                            amount_in_usd_per_day => ''
                        }}}
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
                        for_days                         => '',
                        currency                         => '',
                        limit_for_days                   => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''
                    },
                    malta => {
                        for_days                         => '',
                        currency                         => '',
                        limit_for_days                   => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''
                    },
                    maltainvest => {
                        for_days                         => '',
                        currency                         => '',
                        limit_for_days                   => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''
                    },
                    svg => {
                        for_days                         => '',
                        currency                         => '',
                        limit_for_days                   => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''
                    },
                    "wallet-svg" => {
                        for_days                         => '',
                        currency                         => '',
                        limit_for_days                   => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''
                    },
                    champion => {
                        for_days                         => '',
                        currency                         => '',
                        limit_for_days                   => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''
                    },
                    samoa => {
                        for_days                         => '',
                        currency                         => '',
                        limit_for_days                   => '',
                        limit_for_days_for_authenticated => '',
                        lifetime_limit_for_authenticated => ''
                    }
                },
                qualifying_payment_check_limits => {
                    iom => {
                        for_days       => '',
                        currency       => '',
                        limit_for_days => ''
                    }}
            },
            config => \&BOM::Config::payment_limits
        }
    },
    {
        name => 'client_limts.yml',
        args => {
            expected_config => {
                maximum_daily_turnover => {
                    USD   => '',
                    EUR   => '',
                    AUD   => '',
                    GBP   => '',
                    BTC   => '',
                    ETH   => '',
                    LTC   => '',
                    BUSD  => '',
                    DAI   => '',
                    EURS  => '',
                    IDK   => '',
                    PAX   => '',
                    TUSD  => '',
                    USB   => '',
                    USDC  => '',
                    USDK  => '',
                    UST   => '',
                    eUSDT => ''
                },
                max_balance => {
                    virtual => {
                        USD   => '',
                        EUR   => '',
                        AUD   => '',
                        GBP   => '',
                        BTC   => '',
                        ETH   => '',
                        LTC   => '',
                        BUSD  => '',
                        DAI   => '',
                        EURS  => '',
                        IDK   => '',
                        PAX   => '',
                        TUSD  => '',
                        USB   => '',
                        USDC  => '',
                        USDK  => '',
                        UST   => '',
                        eUSDT => ''
                    },
                    real => {
                        USD   => '',
                        EUR   => '',
                        AUD   => '',
                        GBP   => '',
                        BTC   => '',
                        ETH   => '',
                        LTC   => '',
                        BUSD  => '',
                        DAI   => '',
                        EURS  => '',
                        IDK   => '',
                        PAX   => '',
                        TUSD  => '',
                        USB   => '',
                        USDC  => '',
                        USDK  => '',
                        UST   => '',
                        eUSDT => ''
                    }
                },
                max_payout_open_positions => {
                    USD   => '',
                    EUR   => '',
                    AUD   => '',
                    GBP   => '',
                    BTC   => '',
                    ETH   => '',
                    LTC   => '',
                    BUSD  => '',
                    DAI   => '',
                    EURS  => '',
                    IDK   => '',
                    PAX   => '',
                    TUSD  => '',
                    USB   => '',
                    USDC  => '',
                    USDK  => '',
                    UST   => '',
                    eUSDT => ''
                },
                max_open_bets_default                       => '',
                max_payment_accounts_per_user               => '',
                max_client_payment_accounts_per_broker_code => {
                    MF  => '',
                    MLT => '',
                    MX  => ''
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
                white_list     => [],
                brand          => ''
            },
            config     => \&BOM::Config::domain,
            array_test => ["white_list"],
        }
    },
    {
        name => 's3.yml',
        args => {
            expected_config => {
                document_auth => {
                    aws_bucket            => '',
                    aws_region            => '',
                    aws_access_key_id     => '',
                    aws_secret_access_key => ''
                },
                desk => {
                    aws_bucket            => '',
                    aws_region            => '',
                    aws_access_key_id     => '',
                    aws_secret_access_key => ''
                }
            },
            config => \&BOM::Config::s3
        }
    },
    {
        name => 'feed_rpc.yml',
        args => {
            expected_config => {writer => {feeddb_uri => ''}},
            config          => \&BOM::Config::feed_rpc
        }
    },
    {
        name => 'financial_assessment_structure.yml',
        args => {
            expected_config => {
                trading_experience => {
                    forex_trading_experience => {
                        label           => '',
                        possible_answer => {
                            '0-1 year'     => '',
                            '1-2 years'    => '',
                            'Over 3 years' => ''
                        }
                    },
                    forex_trading_frequency => {
                        label           => '',
                        possible_answer => {
                            '0-5 transactions in the past 12 months'        => '',
                            '6-10 transactions in the past 12 months'       => '',
                            '11-39 transactions in the past 12 months'      => '',
                            '40 transactions or more in the past 12 months' => ''
                        }
                    },
                    binary_options_trading_experience => {
                        label           => '',
                        possible_answer => {
                            '0-1 year'     => '',
                            '1-2 years'    => '',
                            'Over 3 years' => ''
                        }
                    },
                    binary_options_trading_frequency => {
                        label           => '',
                        possible_answer => {
                            '0-5 transactions in the past 12 months'        => '',
                            '6-10 transactions in the past 12 months'       => '',
                            '11-39 transactions in the past 12 months'      => '',
                            '40 transactions or more in the past 12 months' => ''
                        }
                    },
                    cfd_trading_experience => {
                        label           => '',
                        possible_answer => {
                            '0-1 year'     => '',
                            '1-2 years'    => '',
                            'Over 3 years' => ''
                        }
                    },
                    cfd_trading_frequency => {
                        label           => '',
                        possible_answer => {
                            '0-5 transactions in the past 12 months'        => '',
                            '6-10 transactions in the past 12 months'       => '',
                            '11-39 transactions in the past 12 months'      => '',
                            '40 transactions or more in the past 12 months' => ''
                        }
                    },
                    other_instruments_trading_experience => {
                        label           => '',
                        possible_answer => {
                            '0-1 year'     => '',
                            '1-2 years'    => '',
                            'Over 3 years' => ''
                        }
                    },
                    other_instruments_trading_frequency => {
                        label           => '',
                        possible_answer => {
                            '0-5 transactions in the past 12 months'        => '',
                            '6-10 transactions in the past 12 months'       => '',
                            '11-39 transactions in the past 12 months'      => '',
                            '40 transactions or more in the past 12 months' => ''
                        }}
                },
                financial_information => {
                    employment_industry => {
                        label           => '',
                        possible_answer => {
                            'Construction'                            => 0,
                            'Education'                               => 0,
                            'Finance'                                 => 0,
                            'Health'                                  => 0,
                            'Tourism'                                 => 0,
                            'Information & Communications Technology' => 0,
                            'Science & Engineering'                   => 0,
                            'Legal'                                   => 0,
                            'Social & Cultural'                       => 0,
                            'Agriculture'                             => 0,
                            'Real Estate'                             => 0,
                            'Food Services'                           => 0,
                            'Manufacturing'                           => 0,
                            'Unemployed'                              => 0,
                        }
                    },
                    education_level => {
                        label           => '',
                        possible_answer => {
                            'Primary'   => 0,
                            'Secondary' => 0,
                            'Tertiary'  => 0,
                        }
                    },
                    income_source => {
                        label           => '',
                        possible_answer => {
                            'Salaried Employee'       => 0,
                            'Self-Employed'           => 0,
                            'Investments & Dividends' => 0,
                            'Pension'                 => 0,
                            'State Benefits'          => 0,
                            'Savings & Inheritance'   => 0
                        }
                    },
                    net_income => {
                        label           => '',
                        possible_answer => {
                            'Less than $25,000'   => 0,
                            '$25,000 - $50,000'   => 0,
                            '$50,001 - $100,000'  => 0,
                            '$100,001 - $500,000' => 0,
                            'Over $500,000'       => 0,
                        }
                    },
                    estimated_worth => {
                        label           => '',
                        possible_answer => {
                            'Less than $100,000'    => 0,
                            '$100,000 - $250,000'   => 0,
                            '$250,001 - $500,000'   => 0,
                            '$500,001 - $1,000,000' => 0,
                            'Over $1,000,000'       => 0,
                        }
                    },
                    account_turnover => {
                        label           => '',
                        possible_answer => {
                            'Less than $25,000'   => 0,
                            '$25,000 - $50,000'   => 0,
                            '$50,001 - $100,000'  => 0,
                            '$100,001 - $500,000' => 0,
                            'Over $500,000'       => 0,
                        }
                    },
                    occupation => {
                        label           => '',
                        possible_answer => {
                            'Chief Executives, Senior Officials and Legislators'        => 0,
                            'Managers'                                                  => 0,
                            'Professionals'                                             => 0,
                            'Clerks'                                                    => 0,
                            'Personal Care, Sales and Service Workers'                  => 0,
                            'Agricultural, Forestry and Fishery Workers'                => 0,
                            'Craft, Metal, Electrical and Electronics Workers'          => 0,
                            'Plant and Machine Operators and Assemblers'                => 0,
                            'Cleaners and Helpers'                                      => 0,
                            'Mining, Construction, Manufacturing and Transport Workers' => 0,
                            'Armed Forces'                                              => 0,
                            'Government Officers'                                       => 0,
                            'Students'                                                  => 0,
                            'Unemployed'                                                => 0,
                        }
                    },
                    employment_status => {
                        label           => '',
                        possible_answer => {
                            'Employed'      => '',
                            'Pensioner'     => '',
                            'Self-Employed' => '',
                            'Student'       => '',
                            'Unemployed'    => ''
                        }
                    },
                    source_of_wealth => {
                        label           => '',
                        possible_answer => {
                            'Accumulation of Income/Savings' => '',
                            'Cash Business'                  => '',
                            'Company Ownership'              => '',
                            'Divorce Settlement'             => '',
                            'Inheritance'                    => '',
                            'Investment Income'              => '',
                            'Sale of Property'               => ''
                        }}}
            },
            config => \&BOM::Config::financial_assessment_fields
        }
    },
    {
        name => 'social_responsibility_thresholds.yml',
        args => {
            expected_config => {
                limits => [{
                        losses       => '',
                        net_deposits => '',
                        net_income   => '',
                    }]
            },
            config     => \&BOM::Config::social_responsibility_thresholds,
            array_test => ["limits"]}
    },
    {
        name => 'p2p_payment_methods.yml',
        args => {
            expected_config => {
                '2checkout' => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                '543konse' => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                access_money_wallet => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                airtel => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                alipay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                apple_pay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                atease => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                azimo => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                bank_transfer => {
                    display_name => '',
                    fields       => {
                        account   => {display_name => ''},
                        bank_code => {
                            display_name => '',
                            required     => 0
                        },
                        bank_name => {display_name => ''},
                        branch    => {
                            display_name => '',
                            required     => ''
                        }
                    },
                    type => ''
                },
                bitpay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                boss_revolution => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                broadpay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                btc_smega => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                buyonline => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                carbon => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                cashenvoy => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                cassava_remit => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                cellulant => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                celpaid => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                clicknpay_africa => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                clickpesa => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                dpo => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                dusupay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                ecobank_mobilemoney => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                ecocash => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                equitel => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                etranzact => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                ewallet_services_tanzania => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                exchange4free => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                firstmonie => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                flutterwave => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                fnb => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                fortis => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                gcb => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                glo => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                google_pay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                gt_pay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                halotel => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                hubtel => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                instacash => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                inter_pay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                ipay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                kazang => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                konga => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                mascom_my_zaka => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                mlipa => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                mnaira => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                mobicash => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                mobipay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                moov => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                mpesa_tanzania => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                mtn_momo => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                myghpay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                netpay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                nettcash => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                noqodi => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                nownow => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                onemoney => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                opay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                orange_money => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                other => {
                    display_name => '',
                    fields       => {
                        account => {
                            display_name => '',
                            required     => 0
                        },
                        name => {display_name => ''}
                    },
                    type => ''
                },
                paga => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                palmpay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                paxful => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                payant => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                paygate => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                paynow => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                paypal => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                payserv => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                paystack => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                paytoday => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                pesapel => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                pocketmoni => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                posomoney => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                postdotnet => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                qash => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                qless => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                quickteller => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                realpay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                rocket_remit => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                safaricom_mpesa => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                simplepay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                skrill => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                solidpaywave => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                speedpay_mobile => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                sticpay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                stripe => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                talkremit => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                tangaza_pesa => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                teasy_mobile_money => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                teasy_mobile_money => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                telecash => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                terrapay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                tigo_pesa => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                tilt_africa => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                transferwise => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                united_bank_of_zambia_ewallet => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                unitylink => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                vcash => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                vodafone_cash => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                voguepay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                wari => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                wave_mobile_money => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                webmoney => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                wechat_pay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                xapit_zanaco => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                xendpay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                xoom => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                xpress_money => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                yucash => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                yup_africa => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                zamlink => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                zamtel => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                zantel => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                zazu => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                zim_switch => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                zimpayments => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                zoona => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                zotapay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                },
                zympay => {
                    display_name => '',
                    fields       => {account => {display_name => ''}},
                    type         => ''
                }
            },
            config => \&BOM::Config::p2p_payment_methods
        }
    },
    {
        name => 'cft_blocked_countries.yml',
        args => {
            expected_config => {
                bd => {display_name => ''},
                io => {display_name => ''},
                kh => {display_name => ''},
                ca => {display_name => ''},
                co => {display_name => ''},
                hk => {display_name => ''},
                id => {display_name => ''},
                il => {display_name => ''},
                jp => {display_name => ''},
                ls => {display_name => ''},
                mo => {display_name => ''},
                my => {display_name => ''},
                np => {display_name => ''},
                nl => {display_name => ''},
                nz => {display_name => ''},
                pk => {display_name => ''},
                ph => {display_name => ''},
                sg => {display_name => ''},
                za => {display_name => ''},
                kr => {display_name => ''},
                lk => {display_name => ''},
                ch => {display_name => ''},
                th => {display_name => ''},
                tr => {display_name => ''},
                us => {display_name => ''},
                um => {display_name => ''},
                ve => {display_name => ''},
                vn => {display_name => ''},
                vi => {display_name => ''}
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
                        svg         => '',
                        malta       => '',
                        iom         => '',
                        maltainvest => '',
                        samoa       => '',
                        dsl         => ''
                    }}
            },
            config => \&BOM::Config::cashier_config
        }
    },
    {
        name => 'redis-replicated.yml',
        args => {
            expected_config => {
                write => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
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
                    host     => '',
                    port     => '',
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
                    host     => '',
                    port     => '',
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
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
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
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
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
                    host     => '',
                    port     => '',
                    password => ''
                },
                'master-read' => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                write => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                'fake-read' => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                'local' => {
                    host     => '',
                    port     => '',
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
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_mt5_user_config
        }
    },
    {
        name => 'redis-events.yml',
        args => {
            expected_config => {
                write => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_events_config
        }
    },
    {
        name => 'redis-rpc.yml',
        args => {
            expected_config => {
                write => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_rpc_config
        }
    },
    {
        name => 'redis-transaction.yml',
        args => {
            expected_config => {
                write => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_transaction_config
        }
    },
    {
        name => 'redis-transaction-limits.yml',
        args => {
            expected_config => {
                per_landing_company => {
                    svg => {
                        host     => '',
                        port     => '',
                        password => ''
                    },
                    iom => {
                        host     => '',
                        port     => '',
                        password => ''
                    },
                    malta => {
                        host     => '',
                        port     => '',
                        password => ''
                    },
                    maltainvest => {
                        host     => '',
                        port     => '',
                        password => ''
                    },
                    virtual => {
                        host     => '',
                        port     => '',
                        password => ''
                    },
                    champion => {
                        host     => '',
                        port     => '',
                        password => ''
                    },
                    'champion-virtual' => {
                        host     => '',
                        port     => '',
                        password => ''
                    },
                    samoa => {
                        host     => '',
                        port     => '',
                        password => ''
                    },
                    'samoa-virtual' => {
                        host     => '',
                        port     => '',
                        password => ''
                    },
                    dsl => {
                        host     => '',
                        port     => '',
                        password => ''
                    }
                },
                global_settings => {
                    host     => '',
                    port     => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_limit_settings
        }
    },
    {
        name => 'redis-auth.yml',
        args => {
            expected_config => {
                write => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_auth_config
        }
    },
    {
        name => 'redis-expiryq.yml',
        args => {
            expected_config => {
                write => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_expiryq_config
        }
    },
    {
        name => 'redis-p2p.yml',
        args => {
            expected_config => {
                write => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_p2p_config
        }
    },
    {
        name => 'ws-redis.yml',
        args => {
            expected_config => {
                write => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_ws_config
        }
    },
    {
        name => 'mt5_user_rights.yml',
        args => {
            expected_config => {
                rights => {
                    enabled        => '',
                    password       => '',
                    trade_disabled => '',
                    investor       => '',
                    confirmed      => '',
                    trailing       => '',
                    expert         => '',
                    api_deprecated => '',
                    reports        => '',
                    readonly       => '',
                    reset_pass     => '',
                    otp_enabled    => ''
                }
            },
            config => \&BOM::Config::mt5_user_rights
        }
    },
    {
        name => 'mt5_server_routing_by_country.yml',
        args => {
            expected_config => {
                demo => {
                    gb => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    im => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cy => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    dk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ee => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    fi => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    hr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    hu => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ie => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lt => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lv => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    nl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pt => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ro => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    se => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    si => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    be => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    de => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    es => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    it => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lu => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    fr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    au => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ao => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bj => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sh => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mu => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    km => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    za => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ug => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ls => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    na => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ne => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ng => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    zw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ml => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    zm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bi => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    td => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    so => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ga => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gh => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ke => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    st => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ci => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    er => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    et => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cd => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    yt => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    in => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    nz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    kh => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    id => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    la => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ph => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    th => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    vn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    kr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bd => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    np => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bt => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mv => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mo => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    jp => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ar => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bo => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    br => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    co => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ec => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    fk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gp => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gy => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pe => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    uy => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ve => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ag => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ai => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    aw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bb => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bs => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cu => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    dm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    do => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gd => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gt => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    hn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ht => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    jm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    kn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mq => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ms => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mx => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ni => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pa => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sv => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tt => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    vc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gq => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    dz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cv => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    eg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    eh => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ma => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ly => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    dj => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sd => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    kw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    kz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    uz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bh => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tj => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    kg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lb => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sy => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    iq => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ps => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    jo => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sa => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    qa => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    om => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    af => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ye => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    am => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ru => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    al => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    nf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    io => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tv => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cx => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    re => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    az => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    is => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ki => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sb => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ck => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ky => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gi => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sx => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    me => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ws => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    rs => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    hm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ge => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ad => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    li => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    fj => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    md => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ch => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gs => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    by => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    nc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mh => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sj => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bv => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    fo => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    nu => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    fm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ua => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    aq => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ax => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    va => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    wf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    to => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ba => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    nr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    no => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    vg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    an => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bq => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ss => {
                        synthetic => {servers => []},
                        financial => {servers => []}}
                },
                real => {
                    gb => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    im => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    at => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cy => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    dk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ee => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    fi => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    hr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    hu => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ie => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lt => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lv => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    nl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pt => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ro => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    se => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    si => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    be => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    de => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    es => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    it => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lu => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    fr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    au => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ao => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bj => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sh => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mu => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    km => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    za => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ug => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ls => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    na => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ne => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ng => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    zw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ml => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    zm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bi => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    td => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    so => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ga => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gh => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ke => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    st => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ci => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    er => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    et => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cd => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    yt => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    in => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    nz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    kh => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    id => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    la => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ph => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    th => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    vn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    kr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bd => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    np => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bt => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mv => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mo => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    jp => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ar => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bo => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    br => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    co => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ec => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    fk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gp => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gy => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pe => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    uy => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ve => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ag => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ai => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    aw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bb => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bs => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cu => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    dm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    do => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gd => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gt => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    hn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ht => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    jm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    kn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mq => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ms => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mx => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ni => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pa => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sv => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tt => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    vc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gq => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    dz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cv => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    eg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    eh => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ma => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ly => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    dj => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sd => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    kw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    kz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    uz => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bh => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tj => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    kg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    lb => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sy => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    iq => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ps => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    jo => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sa => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    qa => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    om => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    af => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ye => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    am => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ru => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    al => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    nf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    io => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tv => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cx => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    re => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    az => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    is => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ki => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sb => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ck => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ky => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pn => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pw => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gi => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sx => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    me => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ws => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    rs => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    hm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ge => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    tk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ad => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    li => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    fj => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bl => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    pf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    md => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ch => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    gs => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    by => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    nc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mk => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    mh => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    sj => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bv => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    fo => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    nu => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    fm => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    cc => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ua => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    aq => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ax => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    va => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    wf => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    to => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ba => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    nr => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    no => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    vg => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    an => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    bq => {
                        synthetic => {servers => []},
                        financial => {servers => []}
                    },
                    ss => {
                        synthetic => {servers => []},
                        financial => {servers => []}}

                }
            },
            config => \&BOM::Config::mt5_server_routing
        }
    },
    {
        name => 'mt5_account_types.yml',
        args => {
            expected_config => {
                'demo\p01_ts01\financial\labuan_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts01\financial\bvi_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts01\financial\maltainvest_std_gbp' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts01\financial\maltainvest_std_eur' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts01\financial\maltainvest_std_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts01\financial\svg_std_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts01\financial\svg_std-lim_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts01\financial\vanuatu_std_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts01\synthetic\svg_std_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo_bvi_financial_financial_stp' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\bvi_financial_stp' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo01\financial\bvi_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts02\financial\labuan_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts02\financial\bvi_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts02\financial\maltainvest_std_gbp' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts02\financial\maltainvest_std_eur' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts02\financial\svg_std_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts02\financial\svg_std-lim_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts02\financial\vanuatu_std_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts02\synthetic\svg_std_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'demo\p01_ts02\financial\bvi_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\financial\bvi_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\financial\bvi_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\financial\bvi_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\financial\bvi_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\financial\bvi_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\financial\labuan_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\financial\labuan_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\financial\labuan_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\financial\labuan_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\financial\labuan_stp_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\financial\maltainvest_std-hr_eur' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\financial\maltainvest_std-hr_gbp' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\financial\maltainvest_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\financial\maltainvest_std-hr_gbp' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\financial\maltainvest_std-hr_eur' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\financial\maltainvest_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\financial\maltainvest_std-hr_gbp' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\financial\maltainvest_std-hr_eur' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\financial\maltainvest_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\financial\maltainvest_std-hr_gbp' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\financial\maltainvest_std-hr_eur' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\financial\maltainvest_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\financial\maltainvest_std-hr_gbp' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\financial\maltainvest_std-hr_eur' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\financial\maltainvest_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\financial\svg_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\financial\svg_std_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\financial\svg_std-lim_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\financial\svg_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\financial\svg_std_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\financial\svg_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\financial\svg_std_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\financial\svg_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\financial\svg_std_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\financial\svg_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\financial\svg_std_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\financial\vanuatu_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\financial\vanuatu_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\financial\vanuatu_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\financial\vanuatu_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\financial\vanuatu_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\synthetic\svg_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\synthetic\svg_std_usd\01' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\synthetic\svg_std_usd\02' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\synthetic\svg_std_usd\03' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts01\synthetic\svg_std_usd\04' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\synthetic\svg_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\synthetic\svg_std_usd\01' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\synthetic\svg_std_usd\02' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\synthetic\svg_std_usd\03' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\synthetic\svg_std_usd\04' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\synthetic\svg_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\synthetic\svg_std_usd\01' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\synthetic\svg_std_usd\02' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\synthetic\svg_std_usd\03' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\synthetic\svg_std_usd\04' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\synthetic\svg_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\synthetic\svg_std_usd\01' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\synthetic\svg_std_usd\02' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\synthetic\svg_std_usd\03' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\synthetic\svg_std_usd\04' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\synthetic\svg_std-hr_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\synthetic\svg_std_usd\01' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\synthetic\svg_std_usd\02' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\synthetic\svg_std_usd\03' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\synthetic\svg_std_usd\04' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\synthetic\seychelles_ib_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts02\synthetic\seychelles_ibt_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts03\synthetic\seychelles_ibt_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p01_ts04\synthetic\seychelles_ibt_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                },
                'real\p02_ts02\synthetic\seychelles_ibt_usd' => {
                    account_type          => '',
                    landing_company_short => '',
                    market_type           => '',
                    sub_account_type      => '',
                    server                => ''
                }

            },
            config => \&BOM::Config::mt5_account_types
        }
    },
    {
        name => 'redis-payment.yml',
        args => {
            expected_config => {
                write => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_payment_config
        }
    },
    {
        name => 'redis-cfds.yml',
        args => {
            expected_config => {
                write => {
                    host     => '',
                    port     => '',
                    password => ''
                },
                read => {
                    host     => '',
                    port     => '',
                    password => ''
                }
            },
            config => \&BOM::Config::redis_cfds_config
        }
    },
    {
        name => 'services.yml',
        args => {
            expected_config => {
                fraud_prevention => {
                    enabled => '',
                    host    => '',
                    port    => ''
                },
                identity_verification => {
                    enabled => '',
                    host    => '',
                    port    => ''
                }
            },
            config => \&BOM::Config::services_config
        }
    },
    {
        name => 'paymentapi.yml',
        args => {
            expected_config => {secret => ''},
            config          => \&BOM::Config::paymentapi_config
        }
    },
    {
        name => 'quants_config.yml',
        args => {
            expected_config => {
                commission => {
                    intraday => {
                        historical_fixed       => '',
                        historical_vol_meanrev => ''
                    },
                    digital_spread => {level_multiplier     => ''},
                    adjustment     => {forward_start_factor => ''}
                },
                default_stake => {
                    USD   => '',
                    EUR   => '',
                    AUD   => '',
                    GBP   => '',
                    BTC   => '',
                    ETH   => '',
                    LTC   => '',
                    BUSD  => '',
                    DAI   => '',
                    EURS  => '',
                    IDK   => '',
                    PAX   => '',
                    TUSD  => '',
                    USB   => '',
                    USDC  => '',
                    USDK  => '',
                    UST   => '',
                    eUSDT => ''
                },
                bet_limits => {
                    holiday_blackout_start        => '',
                    holiday_blackout_end          => '',
                    inefficient_period_payout_max => {
                        USD   => '',
                        EUR   => '',
                        AUD   => '',
                        GBP   => '',
                        BTC   => '',
                        ETH   => '',
                        LTC   => '',
                        BUSD  => '',
                        DAI   => '',
                        EURS  => '',
                        IDK   => '',
                        PAX   => '',
                        TUSD  => '',
                        USB   => '',
                        USDC  => '',
                        USDK  => '',
                        UST   => '',
                        eUSDT => ''
                    },
                    min_payout => {
                        default_landing_company => {
                            default_market => {
                                default_contract_category => {
                                    USD   => '',
                                    EUR   => '',
                                    AUD   => '',
                                    GBP   => '',
                                    BTC   => '',
                                    ETH   => '',
                                    LTC   => '',
                                    BUSD  => '',
                                    DAI   => '',
                                    EURS  => '',
                                    IDK   => '',
                                    PAX   => '',
                                    TUSD  => '',
                                    USB   => '',
                                    USDC  => '',
                                    USDK  => '',
                                    UST   => '',
                                    eUSDT => ''
                                },
                                callputspread => {
                                    USD   => '',
                                    EUR   => '',
                                    AUD   => '',
                                    GBP   => '',
                                    BTC   => '',
                                    ETH   => '',
                                    LTC   => '',
                                    BUSD  => '',
                                    DAI   => '',
                                    EURS  => '',
                                    IDK   => '',
                                    PAX   => '',
                                    TUSD  => '',
                                    USB   => '',
                                    USDC  => '',
                                    USDK  => '',
                                    UST   => '',
                                    eUSDT => ''
                                }}}
                    },
                    max_payout => {
                        default_landing_company => {
                            default_market => {
                                default_contract_category => {
                                    USD   => '',
                                    EUR   => '',
                                    AUD   => '',
                                    GBP   => '',
                                    BTC   => '',
                                    ETH   => '',
                                    LTC   => '',
                                    BUSD  => '',
                                    DAI   => '',
                                    EURS  => '',
                                    IDK   => '',
                                    PAX   => '',
                                    TUSD  => '',
                                    USB   => '',
                                    USDC  => '',
                                    USDK  => '',
                                    UST   => '',
                                    eUSDT => ''
                                },
                                runs => {
                                    USD   => '',
                                    EUR   => '',
                                    AUD   => '',
                                    GBP   => '',
                                    BTC   => '',
                                    ETH   => '',
                                    LTC   => '',
                                    BUSD  => '',
                                    DAI   => '',
                                    EURS  => '',
                                    IDK   => '',
                                    PAX   => '',
                                    TUSD  => '',
                                    USB   => '',
                                    USDC  => '',
                                    USDK  => '',
                                    UST   => '',
                                    eUSDT => ''
                                },
                                digits => {
                                    USD   => '',
                                    EUR   => '',
                                    AUD   => '',
                                    GBP   => '',
                                    BTC   => '',
                                    ETH   => '',
                                    LTC   => '',
                                    BUSD  => '',
                                    DAI   => '',
                                    EURS  => '',
                                    IDK   => '',
                                    PAX   => '',
                                    TUSD  => '',
                                    USB   => '',
                                    USDC  => '',
                                    USDK  => '',
                                    UST   => '',
                                    eUSDT => ''
                                }}}
                    },
                    min_stake => {
                        default_landing_company => {
                            default_market => {
                                default_contract_category => {
                                    USD   => '',
                                    EUR   => '',
                                    AUD   => '',
                                    GBP   => '',
                                    BTC   => '',
                                    ETH   => '',
                                    LTC   => '',
                                    BUSD  => '',
                                    DAI   => '',
                                    EURS  => '',
                                    IDK   => '',
                                    PAX   => '',
                                    TUSD  => '',
                                    USB   => '',
                                    USDC  => '',
                                    USDK  => '',
                                    UST   => '',
                                    eUSDT => ''
                                },
                                multiplier => {
                                    USD   => '',
                                    EUR   => '',
                                    AUD   => '',
                                    GBP   => '',
                                    BTC   => '',
                                    ETH   => '',
                                    LTC   => '',
                                    BUSD  => '',
                                    DAI   => '',
                                    EURS  => '',
                                    IDK   => '',
                                    PAX   => '',
                                    TUSD  => '',
                                    USB   => '',
                                    USDC  => '',
                                    USDK  => '',
                                    UST   => '',
                                    eUSDT => ''
                                }
                            },
                            synthetic_index => {
                                default_contract_category => {
                                    USD   => '',
                                    EUR   => '',
                                    AUD   => '',
                                    GBP   => '',
                                    BTC   => '',
                                    ETH   => '',
                                    LTC   => '',
                                    BUSD  => '',
                                    DAI   => '',
                                    EURS  => '',
                                    IDK   => '',
                                    PAX   => '',
                                    TUSD  => '',
                                    USB   => '',
                                    USDC  => '',
                                    USDK  => '',
                                    UST   => '',
                                    eUSDT => ''
                                },
                                multiplier => {
                                    USD   => '',
                                    EUR   => '',
                                    AUD   => '',
                                    GBP   => '',
                                    BTC   => '',
                                    ETH   => '',
                                    LTC   => '',
                                    BUSD  => '',
                                    DAI   => '',
                                    EURS  => '',
                                    IDK   => '',
                                    PAX   => '',
                                    TUSD  => '',
                                    USB   => '',
                                    USDC  => '',
                                    USDK  => '',
                                    UST   => '',
                                    eUSDT => ''
                                }}
                        },
                        maltainvest => {
                            default_market => {
                                default_contract_category => {
                                    USD   => '',
                                    EUR   => '',
                                    AUD   => '',
                                    GBP   => '',
                                    BTC   => '',
                                    ETH   => '',
                                    LTC   => '',
                                    BUSD  => '',
                                    DAI   => '',
                                    EURS  => '',
                                    IDK   => '',
                                    PAX   => '',
                                    TUSD  => '',
                                    USB   => '',
                                    USDC  => '',
                                    USDK  => '',
                                    UST   => '',
                                    eUSDT => ''
                                }}}
                    },
                    max_stake => {
                        default_landing_company => {
                            default_market => {
                                multiplier => {
                                    USD   => '',
                                    EUR   => '',
                                    AUD   => '',
                                    GBP   => '',
                                    BTC   => '',
                                    ETH   => '',
                                    LTC   => '',
                                    BUSD  => '',
                                    DAI   => '',
                                    EURS  => '',
                                    IDK   => '',
                                    PAX   => '',
                                    TUSD  => '',
                                    USB   => '',
                                    USDC  => '',
                                    USDK  => '',
                                    UST   => '',
                                    eUSDT => ''
                                }}}
                    },
                    min_commission_amount => {
                        default_contract_category => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        },
                        callputspread => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        }
                    },
                    min_order_amount => {
                        USD   => '',
                        EUR   => '',
                        AUD   => '',
                        GBP   => '',
                        BTC   => '',
                        ETH   => '',
                        LTC   => '',
                        BUSD  => '',
                        DAI   => '',
                        EURS  => '',
                        IDK   => '',
                        PAX   => '',
                        TUSD  => '',
                        USB   => '',
                        USDC  => '',
                        USDK  => '',
                        UST   => '',
                        eUSDT => ''
                    }
                },
                lookback_limits => {
                    crypto         => '',
                    fiat           => '',
                    min_multiplier => {
                        R_10      => '',
                        R_25      => '',
                        R_50      => '',
                        R_75      => '',
                        R_100     => '',
                        '1HZ10V'  => '',
                        '1HZ25V'  => '',
                        '1HZ50V'  => '',
                        '1HZ75V'  => '',
                        '1HZ100V' => ''
                    },
                    open_position_limits => {
                        USD   => '',
                        EUR   => '',
                        AUD   => '',
                        GBP   => '',
                        BTC   => '',
                        ETH   => '',
                        LTC   => '',
                        BUSD  => '',
                        DAI   => '',
                        EURS  => '',
                        IDK   => '',
                        PAX   => '',
                        TUSD  => '',
                        USB   => '',
                        USDC  => '',
                        USDK  => '',
                        UST   => '',
                        eUSDT => ''
                    }
                },
                risk_profile => {
                    no_business => {
                        turnover => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        },
                        payout => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        },
                        multiplier => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        }
                    },
                    extreme_risk => {
                        turnover => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        },
                        payout => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        },
                        multiplier => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        }
                    },
                    high_risk => {
                        turnover => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        },
                        payout => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        },
                        multiplier => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        }
                    },
                    moderate_risk => {
                        turnover => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        },
                        payout => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        },
                        multiplier => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        }
                    },
                    medium_risk => {
                        turnover => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        },
                        payout => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        },
                        multiplier => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        }
                    },
                    low_risk => {
                        turnover => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        },
                        payout => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => ''
                        },
                        multiplier => {
                            USD   => '',
                            EUR   => '',
                            AUD   => '',
                            GBP   => '',
                            BTC   => '',
                            ETH   => '',
                            LTC   => '',
                            BUSD  => '',
                            DAI   => '',
                            EURS  => '',
                            IDK   => '',
                            PAX   => '',
                            TUSD  => '',
                            USB   => '',
                            USDC  => '',
                            USDK  => '',
                            UST   => '',
                            eUSDT => '',
                        }}}
            },
            config => \&BOM::Config::quants
        }
    },
    {
        name => 'onfido_supported_documents.yml',
        args => {
            expected_config => [{
                    country_code   => '',
                    country_name   => '',
                    doc_types_list => [],
                }
            ],
            config        => \&BOM::Config::onfido_supported_documents,
            file_is_array => 1,
        },

    },
    {
        name => 'mt5webapi.yml',
        args => {
            expected_config => {
                demo => {
                    p01_ts01 => {
                        server => {
                            name => '',
                            port => ''
                        },
                        manager => {
                            login    => '',
                            password => ''
                        },
                        accounts => [{
                                from => '',
                                to   => ''
                            }
                        ],
                        group_suffix => '',
                        geolocation  => {
                            region   => '',
                            location => '',
                            sequence => '',
                            group    => ''
                        },
                        environment => ''
                    },
                    p01_ts02 => {
                        server => {
                            name => '',
                            port => ''
                        },
                        manager => {
                            login    => '',
                            password => ''
                        },
                        accounts => [{
                                from => '',
                                to   => ''
                            }
                        ],
                        group_suffix => '',
                        geolocation  => {
                            region   => '',
                            location => '',
                            sequence => '',
                            group    => ''
                        },
                        environment => ''
                    }
                },
                real => {
                    p01_ts01 => {
                        server => {
                            name => '',
                            port => ''
                        },
                        manager => {
                            login    => '',
                            password => ''
                        },
                        accounts => [{
                                from => '',
                                to   => ''
                            }
                        ],
                        group_suffix => '',
                        geolocation  => {
                            region   => '',
                            location => '',
                            sequence => '',
                            group    => ''
                        },
                        environment => ''
                    },
                    p01_ts02 => {
                        server => {
                            name => '',
                            port => ''
                        },
                        manager => {
                            login    => '',
                            password => ''
                        },
                        accounts => [{
                                from => '',
                                to   => ''
                            }
                        ],
                        group_suffix => '',
                        geolocation  => {
                            region   => '',
                            location => '',
                            sequence => '',
                            group    => ''
                        },
                        environment => ''
                    },
                    p01_ts03 => {
                        server => {
                            name => '',
                            port => ''
                        },
                        manager => {
                            login    => '',
                            password => ''
                        },
                        accounts => [{
                                from => '',
                                to   => ''
                            }
                        ],
                        group_suffix => '',
                        geolocation  => {
                            region   => '',
                            location => '',
                            sequence => '',
                            group    => ''
                        },
                        environment => ''
                    },
                    p01_ts04 => {
                        server => {
                            name => '',
                            port => ''
                        },
                        manager => {
                            login    => '',
                            password => ''
                        },
                        accounts => [{
                                from => '',
                                to   => '',
                            }
                        ],
                        group_suffix => '',
                        geolocation  => {
                            region   => '',
                            location => '',
                            sequence => '',
                            group    => ''
                        },
                        environment => ''
                    },
                    p02_ts02 => {
                        server => {
                            name => '',
                            port => ''
                        },
                        manager => {
                            login    => '',
                            password => ''
                        },
                        accounts => [{
                                from => '',
                                to   => '',
                            }
                        ],
                        group_suffix => '',
                        geolocation  => {
                            region   => '',
                            location => '',
                            sequence => '',
                            group    => '',
                        },
                        environment => ''
                    }}
            },
            config     => \&BOM::Config::mt5_webapi_config,
            array_test => [
                "demo:p01_ts01:accounts", "demo:p01_ts02:accounts", "real:p01_ts01:accounts", "real:p01_ts02:accounts",
                "real:p01_ts03:accounts", "real:p01_ts04:accounts", "real:p02_ts02:accounts"
            ]}}];

for my $test_parameter (@$test_parameters) {
    subtest "Test YAML return correct structure for $test_parameter->{name}", \&YamlTestStructure::yaml_structure_validator, $test_parameter->{args};
}

done_testing;