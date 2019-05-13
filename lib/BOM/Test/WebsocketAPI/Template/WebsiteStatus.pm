package BOM::Test::WebsocketAPI::Template::WebsiteStatus;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request website_status => sub {
    return {
        website_status => 1,
    };
};

rpc_request website_status => sub {
    return {
        'website_status' => 1,
    };
};

publish website_status => sub {
    return {
        'NOTIFY::broadcast::channel' => {
            site_status => 'up',
            # a unique message is added, expecting to be delivered to website_status subscribers (needed for sanity checks).
            passthrough => {
                test_publisher_message => 'message #' . ++$_->{counter},
            },
        },
    };
};

rpc_response website_status => sub {
    return {
        api_call_limits => {
            max_proposal_subscription => {
                applies_to => 'subscribing to proposal concurrently',
                max        => 5,
            },
            max_requestes_general => {
                applies_to => 'rest of calls',
                hourly     => 14400,
                minutely   => 180,
            },
            max_requests_outcome => {
                applies_to => 'portfolio, statement and proposal',
                hourly     => 1500,
                minutely   => 25,
            },
            max_requests_pricing => {
                applies_to => 'proposal and proposal_open_contract',
                hourly     => 3600,
                minutely   => 80,
            },
        },
        clients_country   => 'aq',
        currencies_config => {
            AUD => {
                fractional_digits         => 2,
                is_suspended              => 0,
                name                      => 'Dollar',
                stake_default             => 10,
                transfer_between_accounts => {
                    fees => {
                        BCH => 1.0,
                        BTC => 1.0,
                        ETH => 1.0,
                        EUR => 1.0,
                        GBP => 1.0,
                        LTC => 1.0,
                        USB => 0.5,
                        USD => 1.0,
                        UST => 0.5,
                    },
                    limits => {
                        min => 1.0,
                    },
                },
                type => 'fiat',
            },
            BCH => {
                fractional_digits         => 8,
                is_suspended              => 0,
                name                      => 'Bitcoin Cash',
                stake_default             => 0.03,
                transfer_between_accounts => {
                    fees => {
                        AUD => 1.0,
                        EUR => 1.0,
                        GBP => 1.0,
                        USD => 1.0,
                    },
                    limits => {
                        min => 0.002,
                    },
                },
                type => 'crypto',
            },
            BTC => {
                fractional_digits         => 8,
                is_suspended              => 0,
                name                      => 'Bitcoin',
                stake_default             => 0.003,
                transfer_between_accounts => {
                    fees => {
                        AUD => 1.0,
                        EUR => 1.0,
                        GBP => 1.0,
                        USD => 1.0,
                    },
                    limits => {
                        min => 0.002,
                    },
                },
                type => 'crypto',
            },
            ETH => {
                fractional_digits         => 8,
                is_suspended              => 0,
                name                      => 'Ether',
                stake_default             => 0.05,
                transfer_between_accounts => {
                    fees => {
                        AUD => 1.0,
                        EUR => 1.0,
                        GBP => 1.0,
                        USD => 1.0,
                    },
                    limits => {
                        min => 0.002,
                    },
                },
                type => 'crypto',
            },
            EUR => {
                fractional_digits         => 2,
                is_suspended              => 0,
                name                      => 'Euro',
                stake_default             => 10,
                transfer_between_accounts => {
                    fees => {
                        AUD => 1.0,
                        BCH => 1.0,
                        BTC => 1.0,
                        ETH => 1.0,
                        GBP => 1.0,
                        LTC => 1.0,
                        USB => 0.5,
                        USD => 1.0,
                        UST => 0.5,
                    },
                    limits => {
                        min => 1.0,
                    },
                },
                type => 'fiat',
            },
            GBP => {
                fractional_digits         => 2,
                is_suspended              => 0,
                name                      => 'Pound',
                stake_default             => 10,
                transfer_between_accounts => {
                    fees => {
                        AUD => 1.0,
                        BCH => 1.0,
                        BTC => 1.0,
                        ETH => 1.0,
                        EUR => 1.0,
                        LTC => 1.0,
                        USB => 0.5,
                        USD => 1.0,
                        UST => 0.5,
                    },
                    limits => {
                        min => 1.0,
                    },
                },
                type => 'fiat',
            },
            LTC => {
                fractional_digits         => 8,
                is_suspended              => 0,
                name                      => 'Litecoin',
                stake_default             => 0.25,
                transfer_between_accounts => {
                    fees => {
                        AUD => 1.0,
                        EUR => 1.0,
                        GBP => 1.0,
                        USD => 1.0,
                    },
                    limits => {
                        min => 0.002,
                    },
                },
                type => 'crypto',
            },
            USB => {
                fractional_digits         => 2,
                is_suspended              => 0,
                name                      => 'Binary Coin',
                stake_default             => 10,
                transfer_between_accounts => {
                    fees => {
                        AUD => 0.5,
                        EUR => 0.5,
                        GBP => 0.5,
                        USD => 0.5,
                    },
                    limits => {
                        min => 1.0,
                    },
                },
                type => 'crypto',
            },
            USD => {
                fractional_digits         => 2,
                is_suspended              => 0,
                name                      => 'Dollar',
                stake_default             => 10,
                transfer_between_accounts => {
                    fees => {
                        AUD => 1.0,
                        BCH => 1.0,
                        BTC => 1.0,
                        ETH => 1.0,
                        EUR => 1.0,
                        GBP => 1.0,
                        LTC => 1.0,
                        USB => 0.5,
                        UST => 0.5,
                    },
                    limits => {
                        max => 2500.0,
                        min => 1.0,
                    },
                },
                type => 'fiat',
            },
            UST => {
                fractional_digits         => 2,
                is_suspended              => 0,
                name                      => 'Tether',
                stake_default             => 10,
                transfer_between_accounts => {
                    fees => {
                        AUD => 0.5,
                        EUR => 0.5,
                        GBP => 0.5,
                        USD => 0.5,
                    },
                    limits => {
                        min => 1.0,
                    },
                },
                type => 'crypto',
            },
        },
        supported_languages      => ['EN', 'ID', 'RU', 'ES', 'FR', 'IT', 'PT', 'PL', 'DE', 'ZH_CN', 'VI', 'ZH_TW', 'TH'],
        terms_conditions_version => 'Version 1 1970-01-01',
    };
};

1;
