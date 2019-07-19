use strict;
use warnings;

use Test::More;
use Test::MockModule;
use JSON::MaybeUTF8;
use Format::Util::Numbers qw(get_min_unit financialrounding);

use BOM::Config::CurrencyConfig;
use BOM::Config::Runtime;
my %fake_config;
my $revision = 1;

my $mock_app_config = Test::MockModule->new('App::Config::Chronicle', no_auto => 1);
$mock_app_config->mock(
    'set' => sub {
        my ($self, $conf) = @_;
        for (keys %$conf) {
            $fake_config{$_} = $conf->{$_};
        }
    },
    'get' => sub {
        my ($self, $key) = @_;
        if (ref($key) eq 'ARRAY') {
            my %result = map {
                my $value = (defined $fake_config{$_}) ? $fake_config{$_} : $mock_app_config->original('get')->($_);
                $_ => $value
            } @{$key};
            return \%result;
        }
        return $fake_config{$key} if ($fake_config{$key});
        return $mock_app_config->original('get')->(@_);
    },
    'current_revision' => sub {
        return $revision;
    });

subtest 'transfer_between_accounts_limits' => sub {

    my $mock_convert_currency = Test::MockModule->new('BOM::Config::CurrencyConfig', no_auto => 1);
    $mock_convert_currency->mock(
        'convert_currency' => sub {
            my ($amt, $currency, $tocurrency, $seconds) = @_;
            die "No rate available to convert GBP to USD" if ($tocurrency eq 'GBP');
            return 1.2;
        });

    my $minimum = {
        "USD" => 10,
        "GBP" => 11,
        "BTC" => 200,
        "UST" => 210
    };

    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->set({
        'payments.transfer_between_accounts.minimum.by_currency'    => JSON::MaybeUTF8::encode_json_utf8($minimum),
        'payments.transfer_between_accounts.minimum.default.crypto' => 9,
        'payments.transfer_between_accounts.minimum.default.fiat'   => 90,
        'payments.transfer_between_accounts.maximum.default'        => 2500,
    });

    my @all_currencies  = LandingCompany::Registry::all_currencies();
    my $transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1);

    foreach (@all_currencies) {
        my $type = LandingCompany::Registry::get_currency_type($_);
        $type = 'fiat' if LandingCompany::Registry::get_currency_definition($_)->{stable};
        my $min_default = ($type eq 'crypto') ? 9 : 90;

        cmp_ok($transfer_limits->{$_}->{min}, '==', $minimum->{$_} // $min_default, "Transfer between account minimum is correct for $_");
        if ($_ eq 'GBP') {
            is($transfer_limits->{$_}->{max}, undef, "undefined as expected");
        } else {
            cmp_ok(
                $transfer_limits->{$_}->{max},
                '==',
                Format::Util::Numbers::financialrounding('price', $_, 1.2),
                "Transfer between account maximum is correct for $_"
            );
        }
    }
    $mock_convert_currency->unmock_all();

};

subtest 'transfer_between_accounts_lower_bounds' => sub {
    my $rates = {
        USD => 1,
        EUR => 1.2,
        GBP => 1.5,
        JPY => 0.01,
        BTC => 5000,
        BCH => 300,
        LTC => 50,
        ETH => 500,
        UST => 1,
        AUD => 0.8,
        USB => 1
    };
    my $mock_rates = Test::MockModule->new('ExchangeRates::CurrencyConverter', no_auto => 1);
    $mock_rates->mock(
        'in_usd' => sub {
            my ($amount, $currency) = @_;
            return $amount * $rates->{$currency} if $currency ne 'EUR';
            die "EUR not available";
        });

    my $lower_bounds = {
        'BCH' => '0.00005377',
        'BTC' => '0.00000324',
        'USD' => '0.04',
        'AUD' => '0.04',
        'GBP' => '0.03',
        'ETH' => '0.00003227',
        'EUR' => '0.03',
        'UST' => '0.04',
        'LTC' => '0.00032259',
        'USB' => '0.04'
    };

    is_deeply(BOM::Config::CurrencyConfig::transfer_between_accounts_lower_bounds(), $lower_bounds, 'Lower bounds are correct');

    my $min_by_cyrrency = {
        "USD" => 0.001,
        "GBP" => 0.002,
        "BTC" => 0.0000003,
        "UST" => 0.004
    };

    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->set({
        'payments.transfer_between_accounts.minimum.by_currency'    => JSON::MaybeUTF8::encode_json_utf8($min_by_cyrrency),
        'payments.transfer_between_accounts.minimum.default.crypto' => 0.00001,
        'payments.transfer_between_accounts.minimum.default.fiat'   => 0.001,
    });

    my @all_currencies = LandingCompany::Registry::all_currencies();

    my $transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1);
    is_deeply({map { $_ => financialrounding('amount', $_, $transfer_limits->{$_}->{min}) } @all_currencies},
        $lower_bounds, 'Minimum values raised to lower bounds');

    $min_by_cyrrency = {};
    my $expected_min = {
        'BCH' => '0.00100000',
        'BTC' => '0.00100000',
        'USD' => '1.00',
        'AUD' => '1.00',
        'GBP' => '1.00',
        'ETH' => '0.00100000',
        'EUR' => '1.00',
        'UST' => '1.00',
        'LTC' => '0.00100000',
        'USB' => '1.00'
    };
    $app_config->set({
        'payments.transfer_between_accounts.minimum.by_currency'    => JSON::MaybeUTF8::encode_json_utf8($min_by_cyrrency),
        'payments.transfer_between_accounts.minimum.default.crypto' => 0.001,
        'payments.transfer_between_accounts.minimum.default.fiat'   => 1,
    });

    $transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    is_deeply({map { $_ => financialrounding('amount', $_, $transfer_limits->{$_}->{min}) } @all_currencies},
        $lower_bounds, 'Minimum values are unchagend when they are not force to refresh.');

    $transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1);
    is_deeply({map { $_ => financialrounding('amount', $_, $transfer_limits->{$_}->{min}) } @all_currencies},
        $expected_min, 'Minimum values higher than the lower bounds (forced to refresh).');

    $rates->{GBP} = 0.001;

    my $new_transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    is_deeply($new_transfer_limits, $transfer_limits, 'Minimum values are the same if we don_t force refresh.');

    $revision = 2;

    $new_transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    is($new_transfer_limits->{GBP}->{min}, 10.76, 'Minimum values updated with changing app-config revision.');

    $mock_rates->unmock_all();
};

subtest 'transfer_between_accounts_fees' => sub {
    my $currency_fees = {
        "USD_BTC" => 1.1,
        "USD_UST" => 1.2,
        "BTC_EUR" => 1.3,
        "UST_EUR" => 1.4,
        "GBP_USD" => 1.5,
    };

    my $default_fees = {
        'fiat_fiat'   => 2,
        'fiat_crypto' => 3,
        'fiat_stable' => 4,
        'crypto_fiat' => 5,
        'stable_fiat' => 6
    };

    my $app_config = BOM::Config::Runtime->instance->app_config();

    $app_config->set({
        'payments.transfer_between_accounts.fees.default.fiat_fiat'   => 2,
        'payments.transfer_between_accounts.fees.default.fiat_crypto' => 3,
        'payments.transfer_between_accounts.fees.default.fiat_stable' => 4,
        'payments.transfer_between_accounts.fees.default.crypto_fiat' => 5,
        'payments.transfer_between_accounts.fees.default.stable_fiat' => 6,
        'payments.transfer_between_accounts.fees.by_currency'         => JSON::MaybeUTF8::encode_json_utf8($currency_fees),
    });

    my @all_currencies = LandingCompany::Registry::all_currencies();
    my $transfer_fees  = BOM::Config::CurrencyConfig::transfer_between_accounts_fees();

    for my $from_currency (@all_currencies) {
        for my $to_currency (@all_currencies) {
            my $from_def      = LandingCompany::Registry::get_currency_definition($from_currency);
            my $to_def        = LandingCompany::Registry::get_currency_definition($to_currency);
            my $from_category = $from_def->{stable} ? 'stable' : $from_def->{type};
            my $to_category   = $to_def->{stable} ? 'stable' : $to_def->{type};
            my $expected_fee  = -1;
            if (($from_def->{type} ne 'crypto' or $to_def->{type} ne 'crypto') and $from_currency ne $to_currency) {
                $expected_fee = $currency_fees->{"${from_currency}_$to_currency"} // $default_fees->{"${from_category}_$to_category"} // -1;
            }
            is($transfer_fees->{$from_currency}->{$to_currency} // -1,
                $expected_fee, "Transfer between account fee is correct for $from_currency to $to_currency");
        }
    }
};

subtest 'exchange_rate_expiry' => sub {
    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->set({
        'payments.transfer_between_accounts.exchange_rate_expiry.fiat'          => 200,
        'payments.transfer_between_accounts.exchange_rate_expiry.fiat_holidays' => 300,
        'payments.transfer_between_accounts.exchange_rate_expiry.crypto'        => 100,
    });

    my $mock_calendar = Test::MockModule->new('Finance::Calendar');
    $mock_calendar->mock(
        'is_open' => sub {
            return 1;
        });

    is(BOM::Config::CurrencyConfig::rate_expiry('USD', 'EUR'), 200, 'should return fiat expiry if both currencies are fiat');
    is(BOM::Config::CurrencyConfig::rate_expiry('BTC', 'ETH'), 100, 'should return crypto expiry if both currencies are crypto');
    is(BOM::Config::CurrencyConfig::rate_expiry('BTC', 'USD'), 100, 'should return crypto expiry if crypto expiry is less than fiat expiry');

    $app_config->set({'payments.transfer_between_accounts.exchange_rate_expiry.fiat' => 5});
    is(BOM::Config::CurrencyConfig::rate_expiry('BTC', 'USD'), 5, 'should return fiat expiry if fiat expiry is less than crypto expiry');

    $mock_calendar->mock(
        'is_open' => sub {
            return 0;
        });
    is(BOM::Config::CurrencyConfig::rate_expiry('USD', 'EUR'),
        300, 'should return fiat_holidays expiry when market is closed if both currencies are fiat');
};

$mock_app_config->unmock_all();
done_testing();
