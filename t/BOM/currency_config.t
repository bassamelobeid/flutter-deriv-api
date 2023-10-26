use strict;
use warnings;
use utf8;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use JSON::MaybeUTF8;
use JSON::MaybeXS;
use Format::Util::Numbers            qw(get_min_unit financialrounding);
use ExchangeRates::CurrencyConverter qw/convert_currency/;
use List::Util                       qw(max);

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

subtest 'get_mt5_transfer_limit_by_brand' => sub {
    my $mt5_max_limit = {
        default => {
            currency => 'USD',
            amount   => 2500
        },
        derivcrypto => {
            currency => 'BTC',
            amount   => 0.25
        }};

    my $mt5_min_limit = {
        default => {
            currency => 'USD',
            amount   => 1
        },
        derivcrypto => {
            currency => 'BTC',
            amount   => 0.00008
        }};

    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->set({
        'payments.transfer_between_accounts.maximum.MT5'                   => JSON::MaybeUTF8::encode_json_utf8($mt5_max_limit),
        'payments.transfer_between_accounts.minimum.MT5'                   => JSON::MaybeUTF8::encode_json_utf8($mt5_min_limit),
        'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 0,
        'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 0,
    });

    my $expected_config_for_derivCrypto = {
        maximum => {
            currency => 'BTC',
            amount   => 0.25
        },
        minimum => {
            currency => 'BTC',
            amount   => 0.00008
        }};

    my $expected_default_config = {
        maximum => {
            currency => 'USD',
            amount   => 2500
        },
        minimum => {
            currency => 'USD',
            amount   => 1
        }};

    my $derivCrypto_config = BOM::Config::CurrencyConfig::get_mt5_transfer_limit_by_brand('derivcrypto');
    is_deeply $derivCrypto_config, $expected_config_for_derivCrypto, 'Correct config for derivcrypto';

    my $default_config = BOM::Config::CurrencyConfig::get_mt5_transfer_limit_by_brand();
    is_deeply $default_config, $expected_default_config, 'Correct default config';

    $app_config->set({
        'payments.transfer_between_accounts.maximum.MT5'                   => JSON::MaybeUTF8::encode_json_utf8($mt5_max_limit),
        'payments.transfer_between_accounts.minimum.MT5'                   => JSON::MaybeUTF8::encode_json_utf8($mt5_min_limit),
        'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 1,
        'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 150000
    });

    $derivCrypto_config = BOM::Config::CurrencyConfig::get_mt5_transfer_limit_by_brand('derivcrypto');
    is_deeply $derivCrypto_config, $expected_config_for_derivCrypto, 'Correct config for derivcrypto - should not be affected by total daily limit';

    $expected_default_config = {
        maximum => {
            currency => 'USD',
            amount   => 150000
        },
        minimum => {
            currency => 'USD',
            amount   => 1
        }};
    $default_config = BOM::Config::CurrencyConfig::get_mt5_transfer_limit_by_brand();
    is_deeply $default_config, $expected_default_config, 'Correct config using total limit';
};

subtest 'mt5_transfer_limits' => sub {
    my $mt5_max_limit = {
        default => {
            currency => 'USD',
            amount   => 2500
        },
        derivcrypto => {
            currency => 'BTC',
            amount   => 0.25
        }};

    my $mt5_min_limit = {
        default => {
            currency => 'USD',
            amount   => 1
        },
        derivcrypto => {
            currency => 'BTC',
            amount   => 0.00008
        }};

    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->set({
        'payments.transfer_between_accounts.maximum.MT5'                   => JSON::MaybeUTF8::encode_json_utf8($mt5_max_limit),
        'payments.transfer_between_accounts.minimum.MT5'                   => JSON::MaybeUTF8::encode_json_utf8($mt5_min_limit),
        'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 0,
        'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 0,
    });

    my @all_currencies = LandingCompany::Registry::all_currencies();

    my $expected_currency_config = {};
    my $min_amount               = $mt5_min_limit->{default}->{amount};
    my $max_amount               = $mt5_max_limit->{default}->{amount};
    my $min_currency             = $mt5_min_limit->{default}->{currency};
    my $max_currency             = $mt5_max_limit->{default}->{currency};
    for my $currency (@all_currencies) {
        my ($min, $max);

        $min = eval { 0 + financialrounding('amount', $currency, convert_currency($min_amount, $min_currency, $currency)); };
        $max = eval { 0 + financialrounding('amount', $currency, convert_currency($max_amount, $max_currency, $currency)); };

        $expected_currency_config->{$currency}->{min} = $min // 0;
        $expected_currency_config->{$currency}->{max} = $max // 0;
    }

    my $mt5_transfer_limits = BOM::Config::CurrencyConfig::mt5_transfer_limits(1);

    $app_config->set({
        'payments.transfer_between_accounts.maximum.MT5'                   => JSON::MaybeUTF8::encode_json_utf8($mt5_max_limit),
        'payments.transfer_between_accounts.minimum.MT5'                   => JSON::MaybeUTF8::encode_json_utf8($mt5_min_limit),
        'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 1,
        'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 150000,
    });

    $mt5_transfer_limits = BOM::Config::CurrencyConfig::mt5_transfer_limits(1);

    for my $currency (@all_currencies) {
        my ($min, $max);

        $min = eval { 0 + financialrounding('amount', $currency, convert_currency($min_amount, $min_currency, $currency)); };
        $max = eval { 0 + financialrounding('amount', $currency, convert_currency(150000,      $max_currency, $currency)); };

        $expected_currency_config->{$currency}->{min} = $min // 0;
        $expected_currency_config->{$currency}->{max} = $max // 0;
    }

    is_deeply $mt5_transfer_limits, $expected_currency_config, 'correct mt5 limits config';
};

subtest 'get_dxtrade_transfer_limit_by_brand' => sub {
    my $dxtrade_max_limit = {
        default => {
            currency => 'USD',
            amount   => 2500
        },
        derivcrypto => {
            currency => 'DOGE',
            amount   => 42069
        }};

    my $dxtrade_min_limit = {
        default => {
            currency => 'USD',
            amount   => 1
        },
        derivcrypto => {
            currency => 'DOGE',
            amount   => 1
        }};

    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->set({
        'payments.transfer_between_accounts.maximum.dxtrade'                => JSON::MaybeUTF8::encode_json_utf8($dxtrade_max_limit),
        'payments.transfer_between_accounts.minimum.dxtrade'                => JSON::MaybeUTF8::encode_json_utf8($dxtrade_min_limit),
        'payments.transfer_between_accounts.daily_cumulative_limit.enable'  => 0,
        'payments.transfer_between_accounts.daily_cumulative_limit.dxtrade' => 0,
    });

    my $expected_config_for_derivCrypto = {
        maximum => {
            currency => 'DOGE',
            amount   => 42069
        },
        minimum => {
            currency => 'DOGE',
            amount   => 1
        }};

    my $expected_default_config = {
        maximum => {
            currency => 'USD',
            amount   => 2500
        },
        minimum => {
            currency => 'USD',
            amount   => 1
        }};

    my $derivCrypto_config = BOM::Config::CurrencyConfig::get_platform_transfer_limit_by_brand('dxtrade', 'derivcrypto');
    is_deeply $derivCrypto_config, $expected_config_for_derivCrypto, 'Correct config for derivcrypto';

    my $default_config = BOM::Config::CurrencyConfig::get_platform_transfer_limit_by_brand('dxtrade');
    is_deeply $default_config, $expected_default_config, 'Correct default config';

    $app_config->set({
        'payments.transfer_between_accounts.maximum.dxtrade'                => JSON::MaybeUTF8::encode_json_utf8($dxtrade_max_limit),
        'payments.transfer_between_accounts.minimum.dxtrade'                => JSON::MaybeUTF8::encode_json_utf8($dxtrade_min_limit),
        'payments.transfer_between_accounts.daily_cumulative_limit.enable'  => 1,
        'payments.transfer_between_accounts.daily_cumulative_limit.dxtrade' => 25000,
    });

    $derivCrypto_config = BOM::Config::CurrencyConfig::get_platform_transfer_limit_by_brand('dxtrade', 'derivcrypto');
    is_deeply $derivCrypto_config, $expected_config_for_derivCrypto, 'Correct config for derivcrypto - should not be affected by total limit';

    $expected_default_config = {
        maximum => {
            currency => 'USD',
            amount   => 25000
        },
        minimum => {
            currency => 'USD',
            amount   => 1
        }};

    $default_config = BOM::Config::CurrencyConfig::get_platform_transfer_limit_by_brand('dxtrade');
    is_deeply $default_config, $expected_default_config, 'Correct default config for total amount limits';

};

subtest 'dxtrade_transfer_limits' => sub {
    my $dxtrade_max_limit = {
        default => {
            currency => 'USD',
            amount   => 2500
        },
        derivcrypto => {
            currency => 'DOGE',
            amount   => 42069
        }};

    my $dxtrade_min_limit = {
        default => {
            currency => 'USD',
            amount   => 1
        },
        derivcrypto => {
            currency => 'DOGE',
            amount   => 1
        }};

    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->set({
        'payments.transfer_between_accounts.maximum.dxtrade'                => JSON::MaybeUTF8::encode_json_utf8($dxtrade_max_limit),
        'payments.transfer_between_accounts.minimum.dxtrade'                => JSON::MaybeUTF8::encode_json_utf8($dxtrade_min_limit),
        'payments.transfer_between_accounts.daily_cumulative_limit.enable'  => 0,
        'payments.transfer_between_accounts.daily_cumulative_limit.dxtrade' => 0,
    });

    my @all_currencies = LandingCompany::Registry::all_currencies();

    my $expected_currency_config = {};
    my $min_amount               = $dxtrade_min_limit->{default}->{amount};
    my $max_amount               = $dxtrade_max_limit->{default}->{amount};
    my $min_currency             = $dxtrade_min_limit->{default}->{currency};
    my $max_currency             = $dxtrade_max_limit->{default}->{currency};
    for my $currency (@all_currencies) {
        my ($min, $max);

        $min = eval { 0 + financialrounding('amount', $currency, convert_currency($min_amount, $min_currency, $currency)); };
        $max = eval { 0 + financialrounding('amount', $currency, convert_currency($max_amount, $max_currency, $currency)); };

        $expected_currency_config->{$currency}->{min} = $min // 0;
        $expected_currency_config->{$currency}->{max} = $max // 0;
    }

    my $dxtrade_transfer_limits = BOM::Config::CurrencyConfig::platform_transfer_limits('dxtrade', 1);
    is_deeply $dxtrade_transfer_limits, $expected_currency_config, 'correct deriv x limits config';

    $app_config->set({
        'payments.transfer_between_accounts.maximum.dxtrade'                => JSON::MaybeUTF8::encode_json_utf8($dxtrade_max_limit),
        'payments.transfer_between_accounts.minimum.dxtrade'                => JSON::MaybeUTF8::encode_json_utf8($dxtrade_min_limit),
        'payments.transfer_between_accounts.daily_cumulative_limit.enable'  => 1,
        'payments.transfer_between_accounts.daily_cumulative_limit.dxtrade' => 25000,
    });

    for my $currency (@all_currencies) {
        my ($min, $max);

        $min = eval { 0 + financialrounding('amount', $currency, convert_currency($min_amount, $min_currency, $currency)); };
        $max = eval { 0 + financialrounding('amount', $currency, convert_currency(25000,       $max_currency, $currency)); };

        $expected_currency_config->{$currency}->{min} = $min // 0;
        $expected_currency_config->{$currency}->{max} = $max // 0;
    }

    $dxtrade_transfer_limits = BOM::Config::CurrencyConfig::platform_transfer_limits('dxtrade', 1);
    is_deeply $dxtrade_transfer_limits, $expected_currency_config, 'correct deriv x limits config using total limits';

    $app_config->set({
        'payments.transfer_between_accounts.maximum.dxtrade'                => JSON::MaybeUTF8::encode_json_utf8($dxtrade_max_limit),
        'payments.transfer_between_accounts.minimum.dxtrade'                => JSON::MaybeUTF8::encode_json_utf8($dxtrade_min_limit),
        'payments.transfer_between_accounts.daily_cumulative_limit.enable'  => 1,
        'payments.transfer_between_accounts.daily_cumulative_limit.dxtrade' => -1,
    });

    for my $currency (@all_currencies) {
        my ($min, $max);

        $min = eval { 0 + financialrounding('amount', $currency, convert_currency($min_amount, $min_currency, $currency)); };
        $max = eval { 0 + financialrounding('amount', $currency, convert_currency($max_amount, $max_currency, $currency)); };

        $expected_currency_config->{$currency}->{min} = $min // 0;
        $expected_currency_config->{$currency}->{max} = $max // 0;
    }

    $dxtrade_transfer_limits = BOM::Config::CurrencyConfig::platform_transfer_limits('dxtrade', 1);
    is_deeply $dxtrade_transfer_limits, $expected_currency_config, 'correct deriv x limits config using total limits and disabled';
};

subtest 'transfer_between_accounts_limits' => sub {
    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->set({
        'payments.transfer_between_accounts.minimum.default'                         => 1,
        'payments.transfer_between_accounts.maximum.default'                         => 2500,
        'payments.transfer_between_accounts.daily_cumulative_limit.enable'           => 0,
        'payments.transfer_between_accounts.daily_cumulative_limit.between_accounts' => 0,
    });

    my @all_currencies  = LandingCompany::Registry::all_currencies();
    my $transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1);
    my $min_default     = 1;
    for my $currency_code (@all_currencies) {
        my $currency_min_default = convert_currency($min_default, 'USD', $currency_code);

        cmp_ok(
            $transfer_limits->{$currency_code}->{min},
            '==',
            financialrounding('amount', $currency_code, $currency_min_default),
            "Transfer between account minimum is correct for $currency_code"
        );
    }

    $app_config->set({
        'payments.transfer_between_accounts.minimum.default'                         => 1,
        'payments.transfer_between_accounts.maximum.default'                         => 2500,
        'payments.transfer_between_accounts.daily_cumulative_limit.enable'           => 1,
        'payments.transfer_between_accounts.daily_cumulative_limit.between_accounts' => 50000,
    });
    $transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1);
    my $max_default = 50000;
    for my $currency_code (@all_currencies) {
        my $currency_max_default = convert_currency($max_default, 'USD', $currency_code);

        cmp_ok(
            $transfer_limits->{$currency_code}->{max},
            '==',
            financialrounding('amount', $currency_code, $currency_max_default),
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

        is($transfer_limits->{GBP}->{max}, 0, "Default Value is 0 when there is no exchange rate");

        $mock_convert_currency->unmock_all();
    };
};

subtest 'transfer_between_accounts_fees' => sub {
    my $currency_fees = {
        "USD_BTC_all" => 1.1,
        "USD_UST_all" => 1.2,
        "BTC_EUR_all" => 1.3,
        "UST_EUR_all" => 1.4,
        "USD_BTC_ng"  => 1.6,
        "BTC_EUR_ng"  => 1.7,
        "USD_BTC_id"  => 1.8,
    };

    my $default_fees = {
        'fiat_fiat'     => 2,
        'fiat_crypto'   => 3,
        'fiat_stable'   => 4,
        'crypto_crypto' => 5,
        'crypto_fiat'   => 5,
        'crypto_stable' => 5,
        'stable_crypto' => 6,
        'stable_fiat'   => 6,
        'stable_stable' => 6
    };

    my $app_config = BOM::Config::Runtime->instance->app_config();

    $app_config->set({
        'payments.transfer_between_accounts.fees.default.fiat_fiat'     => 2,
        'payments.transfer_between_accounts.fees.default.fiat_crypto'   => 3,
        'payments.transfer_between_accounts.fees.default.fiat_stable'   => 4,
        'payments.transfer_between_accounts.fees.default.crypto_crypto' => 5,
        'payments.transfer_between_accounts.fees.default.crypto_fiat'   => 5,
        'payments.transfer_between_accounts.fees.default.crypto_stable' => 5,
        'payments.transfer_between_accounts.fees.default.stable_crypto' => 6,
        'payments.transfer_between_accounts.fees.default.stable_fiat'   => 6,
        'payments.transfer_between_accounts.fees.default.stable_stable' => 6,
        'payments.transfer_between_accounts.fees.by_currency'           => JSON::MaybeUTF8::encode_json_utf8($currency_fees),
    });

    my @all_currencies = LandingCompany::Registry::all_currencies();
    my $global_fees    = BOM::Config::CurrencyConfig::transfer_between_accounts_fees();

    for my $from_currency (@all_currencies) {
        my $from_def      = LandingCompany::Registry::get_currency_definition($from_currency);
        my $from_category = $from_def->{stable} ? 'stable' : $from_def->{type};
        for my $to_currency (@all_currencies) {
            my $to_def       = LandingCompany::Registry::get_currency_definition($to_currency);
            my $to_category  = $to_def->{stable} ? 'stable' : $to_def->{type};
            my $expected_fee = -1;
            unless ($from_currency eq $to_currency) {
                $expected_fee = $currency_fees->{"${from_currency}_${to_currency}_all"} // $default_fees->{"${from_category}_$to_category"};
            }
            is($global_fees->{$from_currency}->{$to_currency} // -1,
                $expected_fee, "Transfer between account fee is correct for $from_currency to $to_currency");
        }
    }

    my $ng_fees = BOM::Config::CurrencyConfig::transfer_between_accounts_fees('ng');
    my $id_fees = BOM::Config::CurrencyConfig::transfer_between_accounts_fees('id');

    is $global_fees->{USD}{BTC}, 1.1, 'rate for no country, all country override';
    is $ng_fees->{USD}{BTC},     1.6, 'override for a country';
    is $ng_fees->{BTC}{EUR},     1.7, '2nd override for a country';
    is $id_fees->{USD}{BTC},     1.8, 'override for a 2nd country';
    is $id_fees->{BTC}{EUR},     1.3, 'all country override';

    $app_config->set({'payments.transfer_between_accounts.fees.by_currency' => '{}'});
    $revision = 2;
    $ng_fees  = BOM::Config::CurrencyConfig::transfer_between_accounts_fees('ng');
    is $ng_fees->{USD}{BTC}, 3, 'cache is reset when setting changes';
};

subtest 'exchange_rate_expiry' => sub {
    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->set({
        'payments.transfer_between_accounts.exchange_rate_expiry.fiat'                  => 200,
        'payments.transfer_between_accounts.exchange_rate_expiry.fiat_weekend_holidays' => 300,
        'payments.transfer_between_accounts.exchange_rate_expiry.crypto_stable'         => 100,
        'payments.transfer_between_accounts.exchange_rate_expiry.crypto_non_stable'     => 50,
    });

    my $mock_calendar = Test::MockModule->new('Finance::Calendar');
    $mock_calendar->mock(
        'is_open' => sub {
            return 1;
        });

    is(BOM::Config::CurrencyConfig::rate_expiry('USD',  'EUR'), 200, 'should return fiat expiry if both currencies are fiat');
    is(BOM::Config::CurrencyConfig::rate_expiry('TUSD', 'USD'),
        100, 'should return crypto_stable expiry if crypto_stable expiry is less than fiat expiry');
    is(BOM::Config::CurrencyConfig::rate_expiry('BTC', 'ETH'), 50, 'should return crypto_non_stable expiry if both are crypto_non_stable');
    is(BOM::Config::CurrencyConfig::rate_expiry('BTC', 'USD'),
        50, 'should return crypto_non_stable expiry if crypto_non_stable expiry is less than fiat expiry');
    is(BOM::Config::CurrencyConfig::rate_expiry('BTC', 'TUSD'),
        50, 'should return crypto_non_stable expiry crypto_non_stable expiry is less than crypto_stable expiry');
    is(BOM::Config::CurrencyConfig::rate_expiry('TUSD', 'USDC'), 100, 'should return crypto_stable expiry if both are crypto_stable');

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
        ok BOM::Config::CurrencyConfig::is_crypto_currency_deposit_suspended('BTC'),       'Deposit for cryptocurrency is suspended';
        ok !(BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_suspended('BTC')), 'Withdrawal for cryptocurrency is not suspended';
        ok !(BOM::Config::CurrencyConfig::is_crypto_cashier_suspended()),                  'Cryptocashier is not suspended';
        $app_config->system->suspend->cryptocurrencies_deposit([]);
    };

    subtest 'Only when cryptocurrency withdrawal is suspended' => sub {
        $app_config->system->suspend->cryptocurrencies_withdrawal(['BTC']);
        ok BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_suspended('BTC'), 'Withdrawal for cryptocurrency is suspended';
        ok !(BOM::Config::CurrencyConfig::is_crypto_currency_deposit_suspended('BTC')), 'Deposit for cryptocurrency is not suspended';
        ok !(BOM::Config::CurrencyConfig::is_crypto_cashier_suspended()),               'Cryptocashier is not suspended';
        $app_config->system->suspend->cryptocurrencies_withdrawal([]);
    };

    subtest 'Only when cryptocurrency is suspended' => sub {
        $app_config->system->suspend->cryptocurrencies('BTC');
        ok BOM::Config::CurrencyConfig::is_crypto_currency_suspended('BTC'), 'Crypto Currency BTC is suspended';
        $app_config->system->suspend->cryptocurrencies('');
    };

    subtest 'Only when cryptocurrency is suspended' => sub {
        $app_config->system->suspend->cryptocurrencies('ETH');
        ok BOM::Config::CurrencyConfig::is_crypto_currency_suspended('ETH'), 'Crypto Currency ETH is suspended';
        $app_config->system->suspend->cryptocurrencies('');
    };

    subtest 'Only when currency is experimental' => sub {
        $app_config->system->suspend->experimental_currencies(['USB']);
        ok BOM::Config::CurrencyConfig::is_experimental_currency("USB"),    'Currency USB is experimental';
        ok !(BOM::Config::CurrencyConfig::is_experimental_currency("UST")), 'Currency UST is not experimental';
        $app_config->system->suspend->experimental_currencies([]);
    };
};

subtest 'currency config' => sub {
    my $offerings_config = BOM::Config::Runtime->instance->get_offerings_config('sell');
    is $offerings_config->{action},                                              'sell', 'get_offerings_config for sell';
    is BOM::Config::CurrencyConfig::local_currency_for_country(country => 'ca'), 'CAD',  'local_currency_for_country';
};

subtest 'rare currencies config' => sub {
    is BOM::Config::CurrencyConfig::local_currency_for_country(country => 'aq'), 'AAD', 'local currency for Antarctic';
    is BOM::Config::CurrencyConfig::local_currency_for_country(country => 'cw'), 'ANG', 'local currency for Curacao';
    is BOM::Config::CurrencyConfig::local_currency_for_country(country => 'sx'), 'ANG', 'local currency for Sint Maarten (Dutch part)';
    is BOM::Config::CurrencyConfig::local_currency_for_country(country => 'bl'), 'EUR', 'local currency for Saint-Barthemy';
    is BOM::Config::CurrencyConfig::local_currency_for_country(country => 'ax'), 'EUR', 'local currency for Aland Islands';
    is BOM::Config::CurrencyConfig::local_currency_for_country(country => 'mf'), 'EUR', 'local currency for Saint-Martin (French part)';
    is BOM::Config::CurrencyConfig::local_currency_for_country(country => 'an'), 'ANG', 'local currency for Netherlands Antilles';
    is BOM::Config::CurrencyConfig::local_currency_for_country(country => 'ss'), 'SSP', 'local currency for South Sudan';

    is $BOM::Config::CurrencyConfig::ALL_CURRENCIES{BTN}->{name}, 'Bhutanese Ngultrum', 'currency name for Bhutan';
    is $BOM::Config::CurrencyConfig::ALL_CURRENCIES{MNT}->{name}, 'Mongolian Tögrög',   'currency name for Mongolia';
};

subtest 'undefined currency' => sub {
    is BOM::Config::CurrencyConfig::local_currency_for_country(country => undef),   undef, 'undefined country';
    is BOM::Config::CurrencyConfig::local_currency_for_country(country => 'wrong'), undef, 'no currency for country';
};

subtest 'legacy currencies' => sub {
    my @countries  = map  { $_->{countries}->@* } values %BOM::Config::CurrencyConfig::ALL_CURRENCIES;
    my @currencies = grep { my @c = BOM::Config::CurrencyConfig::local_currency_for_country(country => $_); @c != 1; } @countries;
    fail "local_currency_for_country for country $_ returned <> 1 currency" for @currencies;
    pass 'local_currency_for_country returns 1 currency for all countries' unless @currencies;

    for (qw (ec gh mz zm zw)) {
        my @c = BOM::Config::CurrencyConfig::local_currency_for_country(
            country        => $_,
            include_legacy => 1
        );
        ok @c == 2, "country $_ has 2 currencies";
    }

    my @c = BOM::Config::CurrencyConfig::local_currency_for_country(
        country        => 've',
        include_legacy => 1
    );
    ok @c == 3, "country ve has 3 currencies";
};

subtest 'get_crypto_payout_auto_update_global_status' => sub {

    my $apps_config = BOM::Config::Runtime->instance->app_config();

    $apps_config->payments->crypto->auto_update->approve(0);
    $apps_config->payments->crypto->auto_update->reject(0);

    is(BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status(),          0, 'returns false when no action has been passed');
    is(BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('approve'), 0, 'should returns false when auto approve is disabled');
    is(BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('reject'),  0, 'should return false when auto reject is disabled');

    $apps_config->payments->crypto->auto_update->approve(1);
    is(BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('approve'), 1, 'should return true when auto approve is enabled');

    $apps_config->payments->crypto->auto_update->reject(1);
    is(BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('reject'), 1, 'should return true when auto reject is enabled');

    my $expected_result = {
        skrill                 => 'Skrill',
        neteller               => 'Neteller',
        perfectm               => 'Perfect Money',
        fasapay                => 'FasaPay',
        paysafe                => 'PaySafe',
        sticpay                => 'SticPay',
        webmoney               => 'Webmoney',
        airtm                  => 'AirTM',
        paylivre               => 'Paylivre',
        nganluong              => 'NganLuong',
        astropay               => 'Astropay',
        onlinenaira            => 'Onlinenaira',
        directa24s             => 'Directa24',
        zingpay                => 'ZingPay',
        pix                    => 'PIX',
        payrtransfer           => 'PayRTransfer',
        advcash                => 'Advcash',
        upi                    => 'UPI',
        beyonicmt              => 'BeyonicMT',
        imps                   => 'IMPS',
        btc                    => 'BTCCOP',
        ltc                    => 'BTCCOP',
        eth                    => 'BTCCOP',
        bch                    => 'BTCCOP',
        solidpaywave           => 'SolidPayWave',
        verve                  => 'Verve',
        help2pay               => 'Help2pay',
        p2p                    => 'Deriv P2P',
        payment_agent_transfer => 'Payment Agent'
    };
    is_deeply(decode_json(BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('stable_payment_methods')),
        $expected_result, 'should return the correct result for default value of crypto stable payment methods');

    $apps_config->payments->crypto->auto_update->stable_payment_methods('{"skrill" : "Skrill"}');

    $expected_result = {skrill => 'Skrill'};
    is_deeply(decode_json(BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('stable_payment_methods')),
        $expected_result, 'should return the correct result for updated value of crypto stable payment methods');

    $apps_config->payments->crypto->auto_update->approve_dry_run(0);
    $apps_config->payments->crypto->auto_update->reject_dry_run(0);
    is(BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('approve_dry_run'),
        0, 'should return false when approve_dry_run is disabled');
    is(BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('reject_dry_run'),
        0, 'should returns false when reject_dry_run is disabled');

    $apps_config->payments->crypto->auto_update->approve_dry_run(1);
    $apps_config->payments->crypto->auto_update->reject_dry_run(1);

    is(BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('approve_dry_run'),
        1, 'should return true when approve_dry_run is enabled');
    is(BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('reject_dry_run'),
        1, 'should return true when reject_dry_run is enabled');

};

subtest 'local currencies' => sub {
    %BOM::Config::CurrencyConfig::ALL_CURRENCIES = (
        AAA => {
            name      => 'AAA currency',
            countries => ['c1', 'c2'],
        },
        BBB => {
            name      => 'BBB currency',
            countries => ['c3', 'c4'],
        },
    );
    my $local_currencies = BOM::Config::CurrencyConfig::local_currencies;
    is $local_currencies->{'AAA'}, 'AAA currency', 'name';
    is $local_currencies->{'CCC'}, undef,          'no localized name';
};

$mock_app_config->unmock_all();

done_testing();
