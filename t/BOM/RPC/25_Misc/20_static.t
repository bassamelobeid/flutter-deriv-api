use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::RPC::QueueClient;
use BOM::Config::CurrencyConfig;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::Config;
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;

use BOM::User;
use BOM::User::Client;
use BOM::User::Password;
use BOM::RPC::v3::Static;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use JSON::MaybeXS                              qw(decode_json encode_json);

populate_exchange_rates();

# setting redis cache as 0
# else we would have to add sleep in test for TTL
my $mock_static = Test::MockModule->new('BOM::RPC::v3::Static');
$mock_static->mock("STATIC_CACHE_TTL" => 0);

my $c = BOM::Test::RPC::QueueClient->new();
subtest 'residence_list' => sub {
    my $result = $c->call_ok('residence_list', {language => 'EN'})->has_no_system_error->result;
    my $index  = +{map { (delete $_->{value} => $_) } $result->@*};

    is_deeply(
        $index->{cn},
        {
            identity => {
                services => {
                    idv => {
                        is_country_supported => 0,
                        has_visual_sample    => 0,
                        documents_supported  => {},
                    },
                    onfido => {
                        is_country_supported => 0,
                        documents_supported  => {
                            driving_licence             => {display_name => 'Driving Licence'},
                            national_identity_card      => {display_name => 'National Identity Card'},
                            passport                    => {display_name => 'Passport'},
                            residence_permit            => {display_name => 'Residence Permit'},
                            visa                        => {display_name => 'Visa'},
                            immigration_status_document => {display_name => 'Immigration Status Document'},
                        },
                    },
                }
            },
            text       => 'China',
            phone_idd  => '86',
            tin_format => [
                '^\d{18}$',             '^\d{17}[Xx]$',         '^[Cc]\d{17}$',         '^[Cc]\d{16}[A-Za-z]$',
                '^[Ww]\d{17}$',         '^[Ww]\d{16}[A-Za-z]$', '^[Jj]\d{14}$',         '^[Hh]\d{17}$',
                '^[Hh]\d{16}[A-Za-z]$', '^[Mm]\d{17}$',         '^[Mm]\d{16}[A-Za-z]$', '^[Tt]\d{17}$',
                '^[Tt]\d{16}[A-Za-z]$'
            ],
        },
        'cn is correct'
    );

    is_deeply(
        $index->{ng},
        {
            identity => {
                services => {
                    idv => {
                        is_country_supported => 1,
                        has_visual_sample    => 1,
                        documents_supported  => {
                            nin_slip => {
                                display_name => 'National ID Number Slip',
                                format       => '^[0-9]{11}$',
                            },
                            drivers_license => {
                                display_name => 'Drivers License',
                                format       => '^[a-zA-Z]{3}([ -]{1})?[A-Z0-9]{6,12}$',
                            },
                        },
                    },
                    onfido => {
                        is_country_supported => 1,
                        documents_supported  => {
                            driving_licence        => {display_name => 'Driving Licence'},
                            national_identity_card => {display_name => 'National Identity Card'},
                            passport               => {display_name => 'Passport'},
                            voter_id               => {display_name => 'Voter Id'},
                        },
                    },
                }
            },
            text       => 'Nigeria',
            phone_idd  => '234',
            tin_format => ['^\d{8}[-]?0001$', '^\d{10}$'],
        },
        'ng is correct'
    );

    is_deeply(
        $index->{in},
        {
            identity => {
                services => {
                    idv => {
                        is_country_supported => 1,
                        has_visual_sample    => 0,
                        documents_supported  => {
                            aadhaar => {
                                display_name => 'Aadhaar Card',
                                format       => '^[0-9]{12}$',
                                additional   => {
                                    display_name => 'PAN Card',
                                    format       => '^[a-zA-Z]{5}\d{4}[a-zA-Z]{1}$',
                                },
                            },
                            passport => {
                                display_name => 'Passport',
                                format       => '^.{8}$',
                                additional   => {
                                    display_name => 'File Number',
                                    format       => '^.{15}$',
                                },
                            },
                            drivers_license => {
                                display_name => 'Drivers License',
                                format       => '^[a-zA-Z0-9]{10,17}$',
                            },
                            pan => {
                                display_name => 'PAN Card',
                                format       => '^[a-zA-Z]{5}\d{4}[a-zA-Z]{1}$',
                            },
                            epic => {
                                display_name => 'Voter ID',
                                format       => '^[a-zA-Z]{3}[0-9]{7}$',
                            }
                        },
                    },
                    onfido => {
                        is_country_supported => 1,
                        documents_supported  => {
                            driving_licence        => {display_name => 'Driving Licence'},
                            passport               => {display_name => 'Passport'},
                            national_identity_card => {display_name => 'National Identity Card'},
                            voter_id               => {display_name => 'Voter Id'},
                            visa                   => {display_name => 'Visa'}
                        },
                    },
                }
            },
            text       => 'India',
            phone_idd  => '91',
            tin_format => ['^[A-Za-z]{3}P[A-Za-z]\d{4}[A-Za-z]$'],
        },
        'in is correct'
    );

    is_deeply(
        $index->{ug},
        {
            identity => {
                services => {
                    idv => {
                        is_country_supported => 1,
                        has_visual_sample    => 1,
                        documents_supported  => {
                            national_id_no_photo => {
                                display_name => 'National ID Number',
                                format       => '^[a-zA-Z0-9]{14}$',
                                additional   => {
                                    display_name => 'Card Number',
                                    format       => '^[a-zA-Z0-9]+$',
                                },
                            },
                        },
                    },
                    onfido => {
                        is_country_supported => 1,
                        documents_supported  => {
                            driving_licence        => {display_name => 'Driving Licence'},
                            passport               => {display_name => 'Passport'},
                            national_identity_card => {display_name => 'National Identity Card'}
                        },
                    },
                }
            },
            text       => 'Uganda',
            phone_idd  => '256',
            tin_format => ['^\d+$'],
        },
        'ug is correct'
    );

    is_deeply(
        $index->{id},
        {
            tin_format => ['^\d{15,16}$'],
            identity   => {
                services => {
                    onfido => {
                        documents_supported => {
                            passport               => {display_name => 'Passport'},
                            residence_permit       => {display_name => 'Residence Permit'},
                            driving_licence        => {display_name => 'Driving Licence'},
                            national_identity_card => {display_name => 'National Identity Card'}
                        },
                        is_country_supported => 1
                    },
                    idv => {
                        has_visual_sample    => 0,
                        is_country_supported => 1,
                        documents_supported  => {
                            nik => {
                                format       => '^\\d{16}$',
                                display_name => 'Nomor Induk Kependudukan',
                            }}}}
            },
            phone_idd => 62,
            text      => 'Indonesia'
        },
        'Expected Indonesia config'
    );

    BOM::Config::Runtime->instance->app_config->system->suspend->onfido(1);
    $result = $c->call_ok('residence_list', {language => 'EN'})->has_no_system_error->result;
    $index  = +{map { (delete $_->{value} => $_) } $result->@*};
    is_deeply($index->{co}->{identity}->{services}->{onfido}->{is_country_supported}, 0, 'Onfido disabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->onfido(0);

    BOM::Config::Runtime->instance->app_config->system->suspend->idv(1);
    $result = $c->call_ok('residence_list', {language => 'EN'})->has_no_system_error->result;
    $index  = +{map { (delete $_->{value} => $_) } $result->@*};
    is_deeply($index->{ng}->{identity}->{services}->{idv}->{is_country_supported}, 0, 'IDV disabled');

    BOM::Config::Runtime->instance->app_config->system->suspend->idv(0);
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_countries([qw/ng/]);
    $result = $c->call_ok('residence_list', {language => 'EN'})->has_no_system_error->result;
    $index  = +{map { (delete $_->{value} => $_) } $result->@*};
    is_deeply($index->{ng}->{identity}->{services}->{idv}->{is_country_supported}, 0, 'IDV disabled for Nigeria');
    is_deeply($index->{cn}->{identity}->{services}->{idv}->{is_country_supported}, 0, 'IDV not disabled for China');

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_countries([qw//]);
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers([qw/smile_identity/]);
    $result = $c->call_ok('residence_list', {language => 'EN'})->has_no_system_error->result;
    $index  = +{map { (delete $_->{value} => $_) } $result->@*};
    is_deeply($index->{ng}->{identity}->{services}->{idv}->{is_country_supported}, 0, 'IDV disabled for smile_identity');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers([qw//]);

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw/in:pan/]);
    $result = $c->call_ok('residence_list', {language => 'EN'})->has_no_system_error->result;
    $index  = +{map { (delete $_->{value} => $_) } $result->@*};
    is_deeply($index->{in}->{identity}->{services}->{idv}->{is_country_supported}, 1, 'IDV not disabled for India');
    ok !defined $index->{in}->{identity}->{services}->{idv}->{documents_supported}->{pan}, 'IDV disabled for India\'s PAN Card';
    ok defined $index->{in}->{identity}->{services}->{idv}->{documents_supported}->{epic}, 'IDV enabled for India\'s Voter ID';
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw//]);
};

subtest 'states_list' => sub {
    my $result = $c->call_ok(
        'states_list',
        {
            language => 'EN',
            args     => {states_list => 'cn'}})->has_no_system_error->result;
    my ($sh) = grep { $_->{text} eq 'Shanghai Shi' } @$result;
    is_deeply(
        $sh,
        {
            'value' => 'SH',
            'text'  => "Shanghai Shi",
        },
        'Shanghai Shi is correct'
    );
};

subtest 'currencies_config.transfer_between_accounts' => sub {

    my $params_website_status = {
        language     => 'EN',
        country_code => 'id',
        args         => {website_status => 1},
    };

    my $params_website_config = {
        language     => 'EN',
        country_code => 'id',
        args         => {website_config => 1},
    };

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    $app_config->set({'payments.transfer_between_accounts.fees.by_currency' => encode_json({'BTC_USD_all' => 5.1, 'BTC_USD_ng' => 5.2})});

    my $result_ws = $c->call_ok('website_status' => $params_website_status)->has_no_system_error->has_no_error->result;
    my $result_wc = $c->call_ok('website_config' => $params_website_config)->has_no_system_error->has_no_error->result;

    my @all_currencies          = keys %{LandingCompany::Registry->by_name('svg')->legal_allowed_currencies};
    my $currency_limits         = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    my $currency_limits_mt5     = BOM::Config::CurrencyConfig::platform_transfer_limits('MT5');
    my $currency_limits_dxtrade = BOM::Config::CurrencyConfig::platform_transfer_limits('dxtrade');

    for my $currency (@all_currencies) {
        is(
            $currency_limits->{$currency}->{min},
            $result_ws->{currencies_config}->{$currency}->{transfer_between_accounts}->{limits}->{min},
            "Transfer between account minimum is correct for $currency in website_status"
        );

        is(
            $currency_limits->{$currency}->{min},
            $result_wc->{currencies_config}->{$currency}->{transfer_between_accounts}->{limits}->{min},
            "Transfer between account minimum is correct for $currency in website_config"
        );
        is(
            $currency_limits->{$currency}->{max},
            $result_ws->{currencies_config}->{$currency}->{transfer_between_accounts}->{limits}->{max},
            "Transfer between account maximum is correct for $currency in website_status"
        );

        is(
            $currency_limits->{$currency}->{max},
            $result_wc->{currencies_config}->{$currency}->{transfer_between_accounts}->{limits}->{max},
            "Transfer between account maximum is correct for $currency in website_config"
        );

        is(
            $currency_limits_mt5->{$currency}->{min},
            $result_ws->{currencies_config}->{$currency}->{transfer_between_accounts}->{limits_mt5}->{min},
            "MT5 transfer between account minimum is correct for $currency in website_status"
        );
        is(
            $currency_limits_mt5->{$currency}->{min},
            $result_wc->{currencies_config}->{$currency}->{transfer_between_accounts}->{limits_mt5}->{min},
            "MT5 transfer between account minimum is correct for $currency in website_config"
        );

        is(
            $currency_limits_mt5->{$currency}->{max},
            $result_ws->{currencies_config}->{$currency}->{transfer_between_accounts}->{limits_mt5}->{max},
            "Mt5 transfer between account maximum is correct for $currency in website_status"
        );

        is(
            $currency_limits_mt5->{$currency}->{max},
            $result_wc->{currencies_config}->{$currency}->{transfer_between_accounts}->{limits_mt5}->{max},
            "Mt5 transfer between account maximum is correct for $currency in website_config"
        );

        is(
            $currency_limits_dxtrade->{$currency}->{min},
            $result_ws->{currencies_config}->{$currency}->{transfer_between_accounts}->{limits_dxtrade}->{min},
            "dxtrade transfer between account minimum is correct for $currency in website_status"
        );
        is(
            $currency_limits_dxtrade->{$currency}->{min},
            $result_wc->{currencies_config}->{$currency}->{transfer_between_accounts}->{limits_dxtrade}->{min},
            "dxtrade transfer between account minimum is correct for $currency in website_config"
        );

        is(
            $currency_limits_dxtrade->{$currency}->{max},
            $result_ws->{currencies_config}->{$currency}->{transfer_between_accounts}->{limits_dxtrade}->{max},
            "dxtrade transfer between account maximum is correct for $currency in website_status"
        );
        is(
            $currency_limits_dxtrade->{$currency}->{max},
            $result_wc->{currencies_config}->{$currency}->{transfer_between_accounts}->{limits_dxtrade}->{max},
            "dxtrade transfer between account maximum is correct for $currency in website_config"
        );

    }

    my $currency_fees = BOM::Config::CurrencyConfig::transfer_between_accounts_fees('id');

    for my $currency (@all_currencies) {
        cmp_ok(
            $currency_fees->{$currency}->{$_} // -1,
            '==',
            $result_ws->{currencies_config}->{$currency}->{transfer_between_accounts}->{fees}->{$_} // -1,
            "Transfer between account fee is correct for ${currency}_$_ in country id in website_status"
        ) for @all_currencies;

        cmp_ok(
            $currency_fees->{$currency}->{$_} // -1,
            '==',
            $result_wc->{currencies_config}->{$currency}->{transfer_between_accounts}->{fees}->{$_} // -1,
            "Transfer between account fee is correct for ${currency}_$_ in country id in website_config"
        ) for @all_currencies;
    }

    $params_website_config->{country_code} = 'ng';
    $params_website_status->{country_code} = 'ng';
    $result_ws                             = $c->call_ok('website_status' => $params_website_status)->result;
    $result_wc                             = $c->call_ok('website_config' => $params_website_config)->result;
    $currency_fees                         = BOM::Config::CurrencyConfig::transfer_between_accounts_fees('ng');

    for my $currency (@all_currencies) {
        cmp_ok(
            $currency_fees->{$currency}->{$_} // -1,
            '==',
            $result_ws->{currencies_config}->{$currency}->{transfer_between_accounts}->{fees}->{$_} // -1,
            "Transfer between account fee is correct for ${currency}_$_ in country ng in website_status"
        ) for @all_currencies;

        cmp_ok(
            $currency_fees->{$currency}->{$_} // -1,
            '==',
            $result_wc->{currencies_config}->{$currency}->{transfer_between_accounts}->{fees}->{$_} // -1,
            "Transfer between account fee is correct for ${currency}_$_ in country ng in website_config"
        ) for @all_currencies;
    }
};

subtest 'trading_servers' => sub {
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
        residence   => '',
        citizen     => ''
    });

    subtest 'check for restricted and undefined' => sub {
        my $response = BOM::RPC::v3::MT5::Account::get_mt5_server_list(
            client       => $test_client,
            account_type => 'real',
            residence    => $test_client->residence,
        )->get;

        is scalar(@$response), 0, 'empty response if residence is not defined';

        $test_client->residence('rw');
        $test_client->save;

        is scalar(@$response), 0, 'empty response if residence is restricted';
    };

    $test_client->residence('gb');

    my $email = 'sample+1@binary.com';

    $test_client->email($email);
    $test_client->save;

    my $hash_pwd = BOM::User::Password::hashpw('jskjd8292922');

    my $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->add_client($test_client);

    subtest 'Ireland' => sub {
        my $response = BOM::RPC::v3::MT5::Account::get_mt5_server_list(
            client       => $test_client,
            account_type => 'real',
            residence    => $test_client->residence,
        )->get;

        is scalar(@$response),                      1,          'Only one server for country for Ireland server';
        is $response->[0]->{id},                    'p01_ts01', 'correct id for the server';
        is $response->[0]->{geolocation}{region},   'Europe',   'correct region for the server';
        is $response->[0]->{geolocation}{location}, 'Ireland',  'correct location for the server';
        is $response->[0]->{geolocation}{sequence}, '1',        'correct sequence for the server';
        is $response->[1],                          undef,      'no additional server';
    };

    $email       = 'sample+2@binary.com';
    $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'in',
    });
    $test_client->email($email);
    $test_client->save;

    $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->add_client($test_client);

    subtest 'Asia' => sub {
        my $response = BOM::RPC::v3::MT5::Account::get_mt5_server_list(
            client       => $test_client,
            account_type => 'real',
            residence    => $test_client->residence,
            market_type  => 'synthetic',
        )->get;

        is scalar(@$response),                      2,           'Correct number of servers for country';
        is $response->[0]->{id},                    'p01_ts03',  'correct id for the server';
        is $response->[0]->{recommended},           1,           'correct recommended';
        is $response->[0]->{geolocation}{region},   'Asia',      'correct region for the server';
        is $response->[0]->{geolocation}{location}, 'Singapore', 'correct location for the server';
        is $response->[0]->{geolocation}{sequence}, '1',         'correct sequence for the server';

        is $response->[1]->{id},                    'p03_ts01',  'correct id for the server';
        is $response->[1]->{recommended},           0,           'correct recommended';
        is $response->[1]->{geolocation}{region},   'Asia',      'correct region for the server';
        is $response->[1]->{geolocation}{location}, 'Hong Kong', 'correct location for the server';
        is $response->[1]->{geolocation}{sequence}, '3',         'correct sequence for the server';
    };

    $email       = 'sample+3@binary.com';
    $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'za',
    });
    $test_client->email($email);
    $test_client->save;

    $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->add_client($test_client);

    subtest 'Africa' => sub {
        my $response = BOM::RPC::v3::MT5::Account::get_mt5_server_list(
            client       => $test_client,
            account_type => 'real',
            market_type  => 'synthetic',
            residence    => $test_client->residence,
        )->get;
        is scalar(@$response),                      2,              'Correct number of servers for country';
        is $response->[0]->{id},                    'p01_ts02',     'correct id for the server';
        is $response->[0]->{recommended},           1,              'correct recommended';
        is $response->[0]->{geolocation}{region},   'Africa',       'correct region for the server';
        is $response->[0]->{geolocation}{location}, 'South Africa', 'correct location for the server';
        is $response->[0]->{geolocation}{sequence}, '1',            'correct sequence for the server';
        is $response->[1]->{id},                    'p02_ts02',     'correct id for the server';
        is $response->[1]->{recommended},           0,              'Correctly set as not recommended';
        is $response->[1]->{geolocation}{region},   'Africa',       'Correctly sorted';
    };

    $email       = 'sample+4@binary.com';
    $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'br',
    });
    $test_client->email($email);
    $test_client->save;

    $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->add_client($test_client);

    subtest 'Frankfurt' => sub {
        my $response = BOM::RPC::v3::MT5::Account::get_mt5_server_list(
            client       => $test_client,
            account_type => 'real',
            market_type  => 'synthetic',
            residence    => $test_client->residence,
        )->get;

        is scalar(@$response),                      1,           'Correct number of servers for country';
        is $response->[0]->{id},                    'p01_ts04',  'correct id for the server';
        is $response->[0]->{recommended},           1,           'correct recommended';
        is $response->[0]->{geolocation}{region},   'Europe',    'correct region for the server';
        is $response->[0]->{geolocation}{location}, 'Frankfurt', 'correct location for the server';
        is $response->[0]->{geolocation}{sequence}, '1',         'correct sequence for the server';
    };
};

subtest 'p2p_config' => sub {

    my $config        = BOM::Config::Runtime->instance->app_config;
    my $p2p_config    = $config->payments->p2p;
    my $mock_currency = Test::MockModule->new('BOM::Config::CurrencyConfig');
    my %currencies    = (
        AAA => {
            name      => 'AAA currency',
            countries => ['id']
        },
        BBB => {
            name      => 'BBB currency',
            countries => ['ng', 'br']
        },
        CCC => {
            name      => 'CCC currency',
            countries => ['au', 'nz']
        },    # blocked countries for p2p
    );

    $p2p_config->restricted_countries(['au', 'nz']);
    $p2p_config->available_for_currencies(['usd']);
    $p2p_config->cross_border_ads_restricted_countries([]);
    %BOM::Config::CurrencyConfig::ALL_CURRENCIES = %currencies;
    $mock_currency->redefine(local_currency_for_country => sub { my %params = @_; return 'AAA' if $params{country} eq 'id' });
    BOM::Config::Redis->redis_p2p_write->set('P2P::LOCAL_CURRENCIES', 'BBB,CCC');

    my %vals = (
        adverts_active_limit        => 1,
        adverts_archive_period      => 2,
        cancellation_block_duration => 3,
        cancellation_count_period   => 4,
        cancellation_grace_period   => 5,
        cancellation_limit          => 6,
        maximum_advert_amount       => 7,
        maximum_order_amount        => 8,
        order_daily_limit           => 9,
        order_payment_period        => 10,
        supported_currencies        => ["usd"],
        disabled                    => bool(0),
        payment_methods_enabled     => bool(1),
        fixed_rate_adverts          => 'disabled',
        float_rate_adverts          => 'list_only',
        float_rate_offset_limit     => num(4.10),
        fixed_rate_adverts_end_date => '2012-02-03',
        review_period               => 13,
        feature_level               => 14,
        override_exchange_rate      => num(123.45),
        cross_border_ads_enabled    => 1,
        local_currencies            => [{
                symbol       => 'AAA',
                display_name => $currencies{AAA}->{name},
                is_default   => 1,
                has_adverts  => 0,
            },
            {
                symbol       => 'BBB',
                display_name => $currencies{BBB}->{name},
                has_adverts  => 1,
            },
        ],
        block_trade => {
            disabled              => 0,
            maximum_advert_amount => 15,
        },
    );

    $p2p_config->available(1);
    $p2p_config->archive_ads_days($vals{adverts_archive_period});
    $p2p_config->limits->maximum_ads_per_type($vals{adverts_active_limit});
    $p2p_config->cancellation_barring->bar_time($vals{cancellation_block_duration});
    $p2p_config->cancellation_barring->period($vals{cancellation_count_period});
    $p2p_config->cancellation_grace_period($vals{cancellation_grace_period});
    $p2p_config->cancellation_barring->count($vals{cancellation_limit});
    $p2p_config->limits->maximum_advert($vals{maximum_advert_amount});
    $p2p_config->limits->maximum_order($vals{maximum_order_amount});
    $p2p_config->limits->count_per_day_per_client($vals{order_daily_limit});
    $p2p_config->order_timeout($vals{order_payment_period} * 60);
    $p2p_config->review_period($vals{review_period});
    $p2p_config->feature_level($vals{feature_level});
    $p2p_config->enabled(1);
    $config->system->suspend->p2p(0);
    $p2p_config->payment_methods_enabled(1);
    $p2p_config->float_rate_global_max_range(8.2);
    $p2p_config->country_advert_config(
        encode_json({
                'id' => {
                    float_ads        => 'list_only',
                    fixed_ads        => 'disabled',
                    deactivate_fixed => '2012-02-03'
                }}));

    $p2p_config->currency_config(
        encode_json({
                'AAA' => {
                    max_rate_range     => 8.2,
                    manual_quote       => 123.45,
                    manual_quote_epoch => time + 100,
                }}));

    $p2p_config->block_trade->enabled(1);
    $p2p_config->block_trade->maximum_advert(15);

    my %params = (
        website_status => {
            language     => 'EN',
            country_code => 'xxx',
            args         => {website_status => 1},
        },
    );

    my $resp = $c->call_ok(%params)->result;
    is $resp->{clients_country}, 'xxx', 'got country in response';
    ok !exists $resp->{p2p_config}, 'p2p_config not present for unsupported country';

    $params{website_status}->{country_code} = 'id';

    cmp_deeply($c->call_ok(%params)->result->{p2p_config}, \%vals, 'expected results from runtime config');

    $config->system->suspend->p2p(1);
    is $c->call_ok(%params)->result->{p2p_config}{disabled}, 1, 'p2p suspended';

    $config->system->suspend->p2p(0);
    $p2p_config->enabled(0);
    is $c->call_ok(%params)->result->{p2p_config}{disabled}, 1, 'p2p disabled';
};

subtest 'payment_agents config' => sub {
    my $config                = BOM::Config::Runtime->instance->app_config;
    my $payment_agents_config = {
        initial_deposit_per_country => decode_json($config->payment_agents->initial_deposit_per_country),
    };

    my %params_website_status = (
        website_status => {
            language => 'EN',
            args     => {website_status => 1}});

    my %params_website_config = (
        website_config => {
            language => 'EN',
            args     => {website_config => 1}});

    cmp_deeply($c->call_ok(%params_website_status)->result->{payment_agents},
        $payment_agents_config, 'expected results from runtime config from website status');
    cmp_deeply($c->call_ok(%params_website_config)->result->{payment_agents},
        $payment_agents_config, 'expected results from runtime config from website config');

    $payment_agents_config->{initial_deposit_per_country}->{br} = 10000;
    $config->payment_agents->initial_deposit_per_country(encode_json($payment_agents_config->{initial_deposit_per_country}));
    cmp_deeply($c->call_ok(%params_website_status)->result->{payment_agents}, $payment_agents_config, 'expected results from runtime config');
    cmp_deeply($c->call_ok(%params_website_config)->result->{payment_agents}, $payment_agents_config, 'expected results from runtime config');

    $payment_agents_config->{initial_deposit_per_country}->{default} = 20000;
    $payment_agents_config->{initial_deposit_per_country}->{ec}      = 200;
    delete $payment_agents_config->{initial_deposit_per_country}->{br};
    $config->payment_agents->initial_deposit_per_country(encode_json($payment_agents_config->{initial_deposit_per_country}));
    cmp_deeply($c->call_ok(%params_website_status)->result->{payment_agents}, $payment_agents_config, 'expected results from runtime config');
    cmp_deeply($c->call_ok(%params_website_config)->result->{payment_agents}, $payment_agents_config, 'expected results from runtime config');
};

subtest 'broker_codes' => sub {
    my $config = [keys BOM::Config::broker_databases()->%*];
    my %params = (
        website_status => {
            language => 'EN',
            args     => {website_status => 1},
        },
    );

    cmp_deeply($c->call_ok(%params)->result->{broker_codes}, $config, 'expected results from runtime config');
};

subtest 'optional_verification_feature_flag' => sub {
    my $expected_feature_flags = ['signup_with_optional_email_verification'];
    my $app_config             = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    ok($app_config->get('email_verification.suspend.virtual_accounts') eq 0, "Feature flag for optional email verification is disabled by default");

    $app_config->set({'email_verification.suspend.virtual_accounts' => 1});
    my %params = (
        website_config => {
            language => 'EN',
            args     => {website_config => 1},
        },
    );

    my $res = $c->call_ok(%params)->result;
    cmp_deeply($res->{feature_flags}->@*, @$expected_feature_flags, 'Feature flag is enabled and shown in RPC response');

    $app_config->set({'email_verification.suspend.virtual_accounts' => 0});
    $res = $c->call_ok(%params)->result;
    ok(!scalar($res->{feature_flags}->@*), 'Feature flag is disabled and not shown in RPC response');
};

subtest 'test static subs' => sub {
    my $ttl = 2;
    $mock_static->mock("STATIC_CACHE_TTL" => $ttl);

    my $expected_feature_flags = ['signup_with_optional_email_verification'];
    my $app_config             = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    $app_config->set({'email_verification.suspend.virtual_accounts' => 1});
    my %params = (
        website_config => {
            language => 'EN',
            args     => {website_config => 1},
        },
    );

    my $res = $c->call_ok(%params)->result;
    cmp_deeply($res->{feature_flags}->@*, @$expected_feature_flags, 'Feature flag is enabled and shown in RPC response');

    $app_config->set({'email_verification.suspend.virtual_accounts' => 0});
    $res = $c->call_ok(%params)->result;
    cmp_deeply($res->{feature_flags}->@*, @$expected_feature_flags, 'Feature flag is still enabled and shown in RPC response');

    # sleep for more than ttl so that redis key expires
    sleep $ttl + 1;
    $res = $c->call_ok(%params)->result;
    ok(!scalar($res->{feature_flags}->@*), 'Feature flag is disabled and not shown in RPC response');
    $mock_static->unmock("STATIC_CACHE_TTL");
};

done_testing();
