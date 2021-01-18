use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Mojo;
use BOM::Test::RPC::QueueClient;
use BOM::Config::CurrencyConfig;
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
    my ($cn) = grep { $_->{value} eq 'cn' } @$result;
    is_deeply(
        $cn,
        {
            'value'      => 'cn',
            'text'       => "China",
            'phone_idd'  => '86',
            'tin_format' => ['^\d{17}[Xx\d]$', '^[CcWwHhMmTt]\d{16}[xX\d]$', '^[Jj]\d{14}$', '^(\d{15}|\d{18})$', '^\d{8}\w{10}$'],
        },
        'cn is correct'
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

    my @all_currencies      = keys %{LandingCompany::Registry::get('svg')->legal_allowed_currencies};
    my $currency_limits     = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    my $currency_limits_mt5 = BOM::Config::CurrencyConfig::mt5_transfer_limits();
    my $currency_fees       = BOM::Config::CurrencyConfig::transfer_between_accounts_fees();

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
        my $response = BOM::RPC::v3::Static::generate_server_config(
            residence   => $test_client->residence,
            environment => 'env_01'
        );

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
        my $response = BOM::RPC::v3::Static::generate_server_config(
            residence   => $test_client->residence,
            environment => 'env_01'
        );

        is scalar(@$response), 1, 'Only one server for country for Ireland server';
        is $response->[0]->{id}, 'real01', 'correct id for the server';
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
        my $response = BOM::RPC::v3::Static::generate_server_config(
            residence   => $test_client->residence,
            environment => 'env_01'
        );

        is scalar(@$response), 3, 'Correct number of servers for country';
        is $response->[0]->{id},          'real03', 'correct id for the server';
        is $response->[0]->{recommended}, 1,        'correct recommended';
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
        my $response = BOM::RPC::v3::Static::generate_server_config(
            residence   => $test_client->residence,
            environment => 'env_01'
        );

        is scalar(@$response), 3, 'Correct number of servers for country';
        is $response->[0]->{id},          'real02', 'correct id for the server';
        is $response->[0]->{recommended}, 1,        'correct recommended';
        is $response->[0]->{geolocation}{region},   'Africa',       'correct region for the server';
        is $response->[0]->{geolocation}{location}, 'South Africa', 'correct location for the server';
        is $response->[0]->{geolocation}{sequence}, '1',            'correct sequence for the server';
        is $response->[1]->{recommended}, 0, 'Correctly set as not recommended';
        is $response->[1]->{geolocation}{region}, 'Asia', 'Correctly sorted';
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
        my $response = BOM::RPC::v3::Static::generate_server_config(
            residence   => $test_client->residence,
            environment => 'env_01'
        );

        is scalar(@$response), 3, 'Correct number of servers for country';
        is $response->[0]->{id},          'real04', 'correct id for the server';
        is $response->[0]->{recommended}, 1,        'correct recommended';
        is $response->[0]->{geolocation}{region},   'Europe',    'correct region for the server';
        is $response->[0]->{geolocation}{location}, 'Frankfurt', 'correct location for the server';
        is $response->[0]->{geolocation}{sequence}, '1',         'correct sequence for the server';
        is $response->[1]->{recommended}, 0, 'Correctly set as not recommended';
        is $response->[1]->{geolocation}{region}, 'Africa', 'Correctly sorted';
    };
};

done_testing();
