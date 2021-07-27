use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Deep;
use Test::Mojo;
use BOM::Test::RPC::QueueClient;
use BOM::Config::CurrencyConfig;
use BOM::Config::Runtime;
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;
use Format::Util::Numbers qw/financialrounding/;

use BOM::User;
use BOM::User::Client;
use BOM::User::Password;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

populate_exchange_rates();

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
                        is_country_supported => 1,
                        documents_supported  => {
                            driving_licence        => {display_name => 'Driving Licence'},
                            national_identity_card => {display_name => 'National Identity Card'},
                            passport               => {display_name => 'Passport'},
                        },
                    },
                }
            },
            text       => 'China',
            phone_idd  => '86',
            tin_format => ['^\d{17}[Xx\d]$', '^[CcWwHhMmTt]\d{16}[xX\d]$', '^[Jj]\d{14}$', '^(\d{15}|\d{18})$', '^\d{8}\w{10}$'],
        },
        'cn is correct'
    );

    is_deeply(
        $index->{ng},
        {
            identity => {
                services => {
                    idv => {
                        is_country_supported => 0,
                        has_visual_sample    => 1,
                        documents_supported  => {
                            bvn => {
                                display_name => 'BVN',
                                format       => '^[0-9]{11}$'
                            },
                            nin => {
                                display_name => 'NIN',
                                format       => '^[0-9]{11}$',
                            },
                            nin_slip => {
                                display_name => 'NIN Slip',
                                format       => '^[0-9]{11}$',
                            },
                            drivers_license => {
                                display_name => 'Drivers License',
                                format       => '^[a-zA-Z]{3}([ -]{1})?[A-Z0-9]{6,12}$',
                            },
                            voter_id => {
                                display_name => 'Voter ID',
                                format       => '^[a-zA-Z0-9 ]{9,19}$',
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
            tin_format => ['^\d{10}$', '^\d{8}$', '^[A-Za-z]\\d{4,8}$', '^\\d{11}$'],
        },
        'ng is correct'
    );
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

    my $result = $c->call_ok(
        'website_status',
        {
            language => 'EN',
            args     => {website_status => 1}})->has_no_system_error->has_no_error->result;

    my @all_currencies          = keys %{LandingCompany::Registry::get('svg')->legal_allowed_currencies};
    my $currency_limits         = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    my $currency_limits_mt5     = BOM::Config::CurrencyConfig::platform_transfer_limits('MT5');
    my $currency_limits_dxtrade = BOM::Config::CurrencyConfig::platform_transfer_limits('dxtrade');
    my $currency_fees           = BOM::Config::CurrencyConfig::transfer_between_accounts_fees();

    is(
        $currency_limits->{$_}->{min},
        $result->{currencies_config}->{$_}->{transfer_between_accounts}->{limits}->{min},
        "Transfer between account minimum is correct for $_"
    ) for @all_currencies;

    is(
        $currency_limits->{$_}->{max},
        $result->{currencies_config}->{$_}->{transfer_between_accounts}->{limits}->{max},
        "Transfer between account maximum is correct for $_"
    ) for @all_currencies;

    is(
        $currency_limits_mt5->{$_}->{min},
        $result->{currencies_config}->{$_}->{transfer_between_accounts}->{limits_mt5}->{min},
        "MT5 transfer between account minimum is correct for $_"
    ) for @all_currencies;

    is(
        $currency_limits_mt5->{$_}->{max},
        $result->{currencies_config}->{$_}->{transfer_between_accounts}->{limits_mt5}->{max},
        "Mt5 transfer between account maximum is correct for $_"
    ) for @all_currencies;

    is(
        $currency_limits_dxtrade->{$_}->{min},
        $result->{currencies_config}->{$_}->{transfer_between_accounts}->{limits_dxtrade}->{min},
        "dxtrade transfer between account minimum is correct for $_"
    ) for @all_currencies;

    is(
        $currency_limits_dxtrade->{$_}->{max},
        $result->{currencies_config}->{$_}->{transfer_between_accounts}->{limits_dxtrade}->{max},
        "dxtrade transfer between account maximum is correct for $_"
    ) for @all_currencies;

    for my $currency (@all_currencies) {
        cmp_ok(
            $currency_fees->{$currency}->{$_} // -1,
            '==',
            $result->{currencies_config}->{$currency}->{transfer_between_accounts}->{fees}->{$_} // -1,
            "Transfer between account fee is correct for ${currency}_$_"
        ) for @all_currencies;
    }

};

subtest 'crypto_config' => sub {

    my $result = $c->call_ok(
        'website_status',
        {
            language => 'EN',
            args     => {website_status => 1}})->has_no_system_error->has_no_error->result;

    my @all_currencies = keys %{LandingCompany::Registry::get('svg')->legal_allowed_currencies};
    my @currency       = map {
        if (LandingCompany::Registry::get_currency_type($_) eq 'crypto') { $_ }
    } @all_currencies;
    my @crypto_currency = grep { $_ ne '' } @currency;

    cmp_ok(
        0 + financialrounding(
            'amount', $_, ExchangeRates::CurrencyConverter::convert_currency(BOM::Config::crypto()->{$_}->{'withdrawal'}->{min_usd}, 'USD', $_)
        ),
        '==',
        $result->{crypto_config}->{$_}->{minimum_withdrawal},
        "API:website_status:crypto_config=> Minimum withdrawal in USD is correct for $_"
    ) for @crypto_currency;

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

        is scalar(@$response), 1, 'Only one server for country for Ireland server';
        is $response->[0]->{id}, 'p01_ts01', 'correct id for the server';
        is $response->[0]->{geolocation}{region},   'Europe',  'correct region for the server';
        is $response->[0]->{geolocation}{location}, 'Ireland', 'correct location for the server';
        is $response->[0]->{geolocation}{sequence}, '2',       'correct sequence for the server';
        is $response->[1], undef, 'no additional server';
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
        is scalar(@$response), 4, 'Correct number of servers for country';
        is $response->[0]->{id},          'p01_ts03', 'correct id for the server';
        is $response->[0]->{recommended}, 1,          'correct recommended';
        is $response->[0]->{geolocation}{region},   'Asia',      'correct region for the server';
        is $response->[0]->{geolocation}{location}, 'Singapore', 'correct location for the server';
        is $response->[0]->{geolocation}{sequence}, '1',         'correct sequence for the server';
        is $response->[1]->{recommended}, 0, 'Correctly set as not recommended';
        is $response->[1]->{geolocation}{region}, 'Africa', 'Correctly sorted';
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
        is scalar(@$response), 4, 'Correct number of servers for country';
        is $response->[0]->{id},          'p01_ts02', 'correct id for the server';
        is $response->[0]->{recommended}, 1,          'correct recommended';
        is $response->[0]->{geolocation}{region},   'Africa',       'correct region for the server';
        is $response->[0]->{geolocation}{location}, 'South Africa', 'correct location for the server';
        is $response->[0]->{geolocation}{sequence}, '1',            'correct sequence for the server';
        is $response->[1]->{id},          'p02_ts02', 'correct id for the server';
        is $response->[1]->{recommended}, 0,          'Correctly set as not recommended';
        is $response->[1]->{geolocation}{region}, 'Africa', 'Correctly sorted';
        is $response->[2]->{recommended}, 0, 'Correctly set as not recommended';
        is $response->[2]->{geolocation}{region}, 'Asia', 'Correctly sorted';
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

        is scalar(@$response), 4, 'Correct number of servers for country';
        is $response->[0]->{id},          'p01_ts04', 'correct id for the server';
        is $response->[0]->{recommended}, 1,          'correct recommended';
        is $response->[0]->{geolocation}{region},   'Europe',    'correct region for the server';
        is $response->[0]->{geolocation}{location}, 'Frankfurt', 'correct location for the server';
        is $response->[0]->{geolocation}{sequence}, '1',         'correct sequence for the server';
        is $response->[1]->{recommended}, 0, 'Correctly set as not recommended';
        is $response->[1]->{geolocation}{region}, 'Africa', 'Correctly sorted';
    };
};

subtest 'p2p_config' => sub {

    my $p2p_config = BOM::Config::Runtime->instance->app_config->payments->p2p;

    my %vals = (
        adverts_active_limit        => int(rand(1000)),
        adverts_archive_period      => int(rand(1000)),
        cancellation_block_duration => int(rand(1000)),
        cancellation_count_period   => int(rand(1000)),
        cancellation_grace_period   => int(rand(1000)),
        cancellation_limit          => int(rand(1000)),
        maximum_advert_amount       => int(rand(1000)),
        maximum_order_amount        => int(rand(1000)),
        order_daily_limit           => int(rand(1000)),
        order_payment_period        => int(rand(1000)),
    );

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

    my $result = $c->call_ok(
        'website_status',
        {
            language => 'EN',
            args     => {website_status => 1}})->has_no_system_error->has_no_error->result;

    cmp_deeply($result->{p2p_config}, \%vals, 'expected results from runtime config');
};

done_testing();
