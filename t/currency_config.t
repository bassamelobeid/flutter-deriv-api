use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use JSON::MaybeUTF8;
use Format::Util::Numbers qw(get_min_unit financialrounding);
use ExchangeRates::CurrencyConverter qw/convert_currency/;
use List::Util qw(max);

use BOM::Config::CurrencyConfig;
use BOM::Config::Runtime;
use BOM::Config::Redis;

my %all_currencies_rates =
    map { $_ => 1 } LandingCompany::Registry::all_currencies();
my $rates = \%all_currencies_rates;

sub populate_exchange_rates {
    my $local_rates = shift || $rates;
    $local_rates = {%$rates, %$local_rates};
    my $redis = BOM::Config::Redis::redis_exchangerates_write();
    $redis->hmset(
        'exchange_rates::' . $_ . '_USD',
        quote => $local_rates->{$_},
        epoch => time
    ) for keys %$local_rates;

    return;
}

populate_exchange_rates();

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
    my $minimum = {
        USD => 10,
        GBP => 11,
        BTC => 12,
        UST => 15
    };

    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->set({
        'payments.transfer_between_accounts.minimum.by_currency' => JSON::MaybeUTF8::encode_json_utf8($minimum),
        'payments.transfer_between_accounts.minimum.default'     => 1,
        'payments.transfer_between_accounts.maximum.default'     => 2500,
        'payments.transfer_between_accounts.maximum.MT5'         => 2500,
    });

    my @all_currencies  = LandingCompany::Registry::all_currencies();
    my $transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1);
    my $min_default     = 1;
    for my $currency_code (@all_currencies) {
        my $currency_min_default = convert_currency($minimum->{$currency_code} // $min_default, 'USD', $currency_code);

        cmp_ok(
            $transfer_limits->{$currency_code}->{min},
            '==',
            financialrounding('amount', $currency_code, $currency_min_default),
            "Transfer between account minimum is correct for $currency_code"
        );
    }

    subtest 'No rate available' => sub {
        my $mock_convert_currency = Test::MockModule->new('BOM::Config::CurrencyConfig', no_auto => 1);
        $mock_convert_currency->mock(
            'convert_currency' => sub {
                my ($amt, $currency, $tocurrency, $seconds) = @_;
                die "No rate available to convert GBP to USD" if ($tocurrency eq 'GBP');
                return 1;
            });

        $transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1);

        is($transfer_limits->{GBP}->{max}, undef, "No error thrown when there is no exchange rate");

        $mock_convert_currency->unmock_all();
    };
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

subtest 'is_valid_currency' => sub {
    ok BOM::Config::CurrencyConfig::is_valid_currency($_), "Currency '$_' is valid" for LandingCompany::Registry::all_currencies();

    ok !BOM::Config::CurrencyConfig::is_valid_currency('INVALID'), "Currency 'INVALID' is not valid";
    ok !BOM::Config::CurrencyConfig::is_valid_currency('usd'),     "Currency with wrong case 'usd' is not valid";
};

subtest 'is_valid_crypto_currency' => sub {
    ok BOM::Config::CurrencyConfig::is_valid_crypto_currency($_), "Currency '$_' is valid" for LandingCompany::Registry::all_crypto_currencies();

    ok !BOM::Config::CurrencyConfig::is_valid_crypto_currency('INVALID'), "Currency 'INVALID' is not valid";
    ok !BOM::Config::CurrencyConfig::is_valid_crypto_currency('USD'),     "Fiat currency is not a valid crypto currency";
};

subtest 'Check Types of Suspension' => sub {
    my $app_config = BOM::Config::Runtime->instance->app_config();

    subtest 'When payments is suspended' => sub {
        $app_config->system->suspend->payments(1);
        ok BOM::Config::CurrencyConfig::is_payment_suspended,        'Payments is suspended';
        ok BOM::Config::CurrencyConfig::is_crypto_cashier_suspended, 'Crypto Cashier is suspended';
        ok BOM::Config::CurrencyConfig::is_cashier_suspended,        'Cashier is suspended';
        $app_config->system->suspend->payments(0);
    };

    subtest 'When cryptocashier is suspended' => sub {
        $app_config->system->suspend->cryptocashier(1);
        ok BOM::Config::CurrencyConfig::is_crypto_cashier_suspended, 'Crypto Cashier is suspended';
        $app_config->system->suspend->cryptocashier(0);
    };

    subtest 'When cashier is suspended' => sub {
        $app_config->system->suspend->cashier(1);
        ok BOM::Config::CurrencyConfig::is_cashier_suspended, 'Cashier is suspended';
        $app_config->system->suspend->cashier(0);
    };

    subtest 'When cryptocurrency is suspended' => sub {
        like(
            exception { BOM::Config::CurrencyConfig::is_crypto_currency_suspended() },
            qr/Expected currency code parameter/,
            'Dies when no currency is passed'
        );
        like(
            exception { BOM::Config::CurrencyConfig::is_crypto_currency_suspended('USD') },
            qr/Failed to accept USD as a cryptocurrency/,
            'Dies when is not a crypto currency'
        );
        $app_config->system->suspend->cryptocurrencies('BTC');
        ok BOM::Config::CurrencyConfig::is_crypto_currency_suspended('BTC'),            'Crypto Currency BTC is suspended';
        ok BOM::Config::CurrencyConfig::is_crypto_currency_deposit_suspended('BTC'),    'Deposit for cryptocurrency is suspended';
        ok BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_suspended('BTC'), 'Withdrawal for cryptocurrency is suspended';
        $app_config->system->suspend->cryptocurrencies("");
    };

    subtest 'Only when cryptocurrency deposit is suspended' => sub {
        $app_config->system->suspend->cryptocurrencies_deposit(['BTC']);
        ok BOM::Config::CurrencyConfig::is_crypto_currency_deposit_suspended('BTC'), 'Deposit for cryptocurrency is suspended';
        ok !(BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_suspended('BTC')), 'Withdrawal for cryptocurrency is not suspended';
        ok !(BOM::Config::CurrencyConfig::is_crypto_cashier_suspended()), 'Cryptocashier is not suspended';
        $app_config->system->suspend->cryptocurrencies_deposit([]);
    };

    subtest 'Only when cryptocurrency withdrawal is suspended' => sub {
        $app_config->system->suspend->cryptocurrencies_withdrawal(['BTC']);
        ok BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_suspended('BTC'), 'Withdrawal for cryptocurrency is suspended';
        ok !(BOM::Config::CurrencyConfig::is_crypto_currency_deposit_suspended('BTC')), 'Deposit for cryptocurrency is not suspended';
        ok !(BOM::Config::CurrencyConfig::is_crypto_cashier_suspended()), 'Cryptocashier is not suspended';
        $app_config->system->suspend->cryptocurrencies_withdrawal([]);
    };

    subtest 'Only when currency is experimental' => sub {
        $app_config->system->suspend->experimental_currencies(['USB']);
        ok BOM::Config::CurrencyConfig::is_experimental_currency("USB"), 'Currency USB is experimental';
        ok !(BOM::Config::CurrencyConfig::is_experimental_currency("UST")), 'Currency UST is not experimental';
        $app_config->system->suspend->experimental_currencies([]);
    };
};

$mock_app_config->unmock_all();

done_testing();
