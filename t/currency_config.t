use strict;
use warnings;

use Test::More;
use Test::MockModule;
use JSON::MaybeUTF8;
use Format::Util::Numbers qw(get_min_unit financialrounding);
use ExchangeRates::CurrencyConverter qw/convert_currency/;
use List::Util qw(max);

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
    'loaded_revision' => sub {
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

sub check_lower_bound {
    my ($currency, $lower_bound) = @_;
    my @all_currencies = LandingCompany::Registry::all_currencies();

    for my $to_currency (@all_currencies) {
        my $transfer_fee = max(get_min_unit($currency), $lower_bound * BOM::Config::CurrencyConfig::MAX_TRANSFER_FEE / 100);
        my $remaining_amount = convert_currency($lower_bound - $transfer_fee, $currency, $to_currency);
        return
            "Lower bound $lower_bound for $currency is incorrect. Remaining amount $remaining_amount is less than the minimum unit of $to_currency"
            if $remaining_amount < get_min_unit($to_currency);
    }
    return '';
}

subtest 'transfer_between_accounts_lower_bounds old' => sub {
    my $rates = {
        USD => 1,
        EUR => 1.2,
        GBP => 1.5,
        JPY => 0.01,
        BTC => 5000,
        LTC => 50,
        ETH => 500,
        UST => 1,
        AUD => 0.8,
        USB => 1,
        IDK => 1,
    };
    my $mock_rates = Test::MockModule->new('ExchangeRates::CurrencyConverter', no_auto => 1);
    $mock_rates->mock(
        'in_usd' => sub {
            my ($amount, $currency) = @_;
            return $amount * $rates->{$currency};
        });

    my @all_currencies = LandingCompany::Registry::all_currencies();
    my %lower_bounds   = BOM::Config::CurrencyConfig::transfer_between_accounts_lower_bounds()->%*;

    for my $currency (@all_currencies) {
        is check_lower_bound($currency, $lower_bounds{$currency}), '', "Acceptable lower bound for currency $currency";
    }

    for my $currency (@all_currencies) {
        like check_lower_bound($currency, $lower_bounds{$currency} - get_min_unit($currency)),
            qr'Remaining amount .* is less than the minimum unit of',
            "Any amount less than lower bound of sending currency ($currency) will make zero received amount at least on one receiving currency";
    }

    grep { ok($lower_bounds{$_}, "$_ Lower bounds contains all currencies with valid values") } @all_currencies;

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

    $min_by_cyrrency = {};
    my $expected_min = {
        'BTC' => '0.00100000',
        'USD' => '1.00',
        'AUD' => '1.00',
        'GBP' => '1.00',
        'ETH' => '0.00100000',
        'EUR' => '1.00',
        'UST' => '1.00',
        'LTC' => '0.00100000',
        'USB' => '1.00',
        'IDK' => '1',
    };
    $app_config->set({
        'payments.transfer_between_accounts.minimum.by_currency'    => JSON::MaybeUTF8::encode_json_utf8($min_by_cyrrency),
        'payments.transfer_between_accounts.minimum.default.crypto' => 0.001,
        'payments.transfer_between_accounts.minimum.default.fiat'   => 1,
    });

    my $transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1);
    for my $currency (@all_currencies) {
        ok $transfer_limits->{$currency}->{min}, "Lower bounds contains $currency with valid values";
    }

    $rates->{GBP} = 0.001;

    my $new_transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    is_deeply($new_transfer_limits, $transfer_limits, 'Minimum values are the same if we don_t force refresh.');

    $revision = 2;

    $new_transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    ok $new_transfer_limits->{GBP}->{min}, 'Minimum values updated with changing app-config revision.';

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
