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
        'payments.transfer_between_accounts.maximum.MT5' => JSON::MaybeUTF8::encode_json_utf8($mt5_max_limit),
        'payments.transfer_between_accounts.minimum.MT5' => JSON::MaybeUTF8::encode_json_utf8($mt5_min_limit),
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
        'payments.transfer_between_accounts.maximum.MT5' => JSON::MaybeUTF8::encode_json_utf8($mt5_max_limit),
        'payments.transfer_between_accounts.minimum.MT5' => JSON::MaybeUTF8::encode_json_utf8($mt5_min_limit),
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
        'payments.transfer_between_accounts.maximum.dxtrade' => JSON::MaybeUTF8::encode_json_utf8($dxtrade_max_limit),
        'payments.transfer_between_accounts.minimum.dxtrade' => JSON::MaybeUTF8::encode_json_utf8($dxtrade_min_limit),
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
        'payments.transfer_between_accounts.maximum.dxtrade' => JSON::MaybeUTF8::encode_json_utf8($dxtrade_max_limit),
        'payments.transfer_between_accounts.minimum.dxtrade' => JSON::MaybeUTF8::encode_json_utf8($dxtrade_min_limit),
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
};

subtest 'transfer_between_accounts_limits' => sub {
    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->set({
        'payments.transfer_between_accounts.minimum.default' => 1,
        'payments.transfer_between_accounts.maximum.default' => 2500,
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
        "USD_BTC" => 1.1,
        "USD_UST" => 1.2,
        "BTC_EUR" => 1.3,
        "UST_EUR" => 1.4,
        "GBP_USD" => 1.5,
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
    my $transfer_fees  = BOM::Config::CurrencyConfig::transfer_between_accounts_fees();

    for my $from_currency (@all_currencies) {
        my $from_def      = LandingCompany::Registry::get_currency_definition($from_currency);
        my $from_category = $from_def->{stable} ? 'stable' : $from_def->{type};
        for my $to_currency (@all_currencies) {
            my $to_def       = LandingCompany::Registry::get_currency_definition($to_currency);
            my $to_category  = $to_def->{stable} ? 'stable' : $to_def->{type};
            my $expected_fee = -1;
            unless ($from_currency eq $to_currency) {
                $expected_fee = $currency_fees->{"${from_currency}_$to_currency"} // $default_fees->{"${from_category}_$to_category"};
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
        ok BOM::Config::CurrencyConfig::is_crypto_currency_deposit_stopped('BTC'),      'Deposit for cryptocurrency is stopped';
        ok BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_stopped('BTC'),   'Withdrawal for cryptocurrency is stopped';
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

    subtest 'Only when cryptocurrency deposit is stopped' => sub {
        $app_config->system->stop->cryptocurrencies_deposit(['BTC']);
        ok BOM::Config::CurrencyConfig::is_crypto_currency_deposit_stopped('BTC'), 'Deposit for cryptocurrency is stopped';
        ok !(BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_stopped('BTC')), 'Withdrawal for cryptocurrency is not stopped';
        $app_config->system->stop->cryptocurrencies_deposit([]);
    };

    subtest 'Only when cryptocurrency withdrawal is stopped' => sub {
        $app_config->system->stop->cryptocurrencies_withdrawal(['BTC']);
        ok BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_stopped('BTC'), 'Withdrawal for cryptocurrency is stopped';
        ok !(BOM::Config::CurrencyConfig::is_crypto_currency_deposit_stopped('BTC')), 'Deposit for cryptocurrency is not stopped';
        $app_config->system->stop->cryptocurrencies_withdrawal([]);
    };

    subtest 'Only when cryptocurrency is suspended' => sub {
        $app_config->system->suspend->cryptocurrencies('BTC');
        ok BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_stopped('BTC'), 'Withdrawal for cryptocurrency is stopped';
        ok BOM::Config::CurrencyConfig::is_crypto_currency_deposit_stopped('BTC'),    'Deposit for cryptocurrency is stopped';
        $app_config->system->suspend->cryptocurrencies('');
    };

    subtest 'Only when cryptocurrency is suspended' => sub {
        $app_config->system->suspend->cryptocurrencies('ETH');
        ok !(BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_stopped('BTC')), 'Withdrawal for cryptocurrency is stopped';
        ok !(BOM::Config::CurrencyConfig::is_crypto_currency_deposit_stopped('BTC')),    'Deposit for cryptocurrency is stopped';
        $app_config->system->suspend->cryptocurrencies('');
    };

    subtest 'Only when currency is experimental' => sub {
        $app_config->system->suspend->experimental_currencies(['USB']);
        ok BOM::Config::CurrencyConfig::is_experimental_currency("USB"), 'Currency USB is experimental';
        ok !(BOM::Config::CurrencyConfig::is_experimental_currency("UST")), 'Currency UST is not experimental';
        $app_config->system->suspend->experimental_currencies([]);
    };
};

subtest 'currency config' => sub {
    my $offerings_config = BOM::Config::Runtime->instance->get_offerings_config('sell');
    is $offerings_config->{action}, 'sell', 'get_offerings_config for sell';
    is BOM::Config::CurrencyConfig::local_currency_for_country('ca'),           'CAD',   'local_currency_for_country';
    is BOM::Config::CurrencyConfig::get_crypto_withdrawal_fee_limit('BTC'),     '10',    'get_crypto_withdrawal_fee_limit';
    is BOM::Config::CurrencyConfig::get_currency_wait_before_bump('BTC'),       '43200', 'get_currency_wait_before_bump';
    is BOM::Config::CurrencyConfig::get_crypto_new_address_threshold('BTC'),    '0.003', 'get_crypto_new_address_threshold';
    is BOM::Config::CurrencyConfig::get_currency_external_sweep_address('BTC'), '1QEdWqpiEfWMCGLHmmABLFqym8SSeib8Ks',
        'correct external sweep address set for BTC';
    is BOM::Config::CurrencyConfig::get_currency_external_sweep_address('eUSDT'), '0x067f48d1BbaAb135cFBe43535Cc34312FACc54a1',
        'correct external sweep address set for eUSDT';
    is BOM::Config::CurrencyConfig::get_currency_external_sweep_address('USDK'), '',
        'correct empty address as no external sweep address set for USDK';
};

subtest 'get_currency_internal_sweep_config' => sub {
    my $app_config                 = BOM::Config::Runtime->instance->app_config();
    my $amounts_original           = $app_config->payments->crypto->internal_sweep->amounts();
    my $fee_rate_percent_original  = $app_config->payments->crypto->internal_sweep->fee_rate_percent();
    my $fee_limit_percent_original = $app_config->payments->crypto->internal_sweep->fee_limit_percent();

    # Change the config
    $app_config->set({
        'payments.crypto.internal_sweep.amounts'           => '{"LTC":[1]}',
        'payments.crypto.internal_sweep.fee_rate_percent'  => '{"LTC":80}',
        'payments.crypto.internal_sweep.fee_limit_percent' => '{"LTC":2}',
    });

    my $expected_btc_config = {
        amounts           => [],
        fee_rate_percent  => 100,
        fee_limit_percent => 1
    };
    my $expected_ltc_config = {
        amounts           => [1],
        fee_rate_percent  => 80,
        fee_limit_percent => 2
    };

    is_deeply BOM::Config::CurrencyConfig::get_currency_internal_sweep_config('BTC'), $expected_btc_config, 'Correct default config';
    is_deeply BOM::Config::CurrencyConfig::get_currency_internal_sweep_config('LTC'), $expected_ltc_config, 'Correct currecny config';

    # Revert the chages
    $app_config->set({
        'payments.crypto.internal_sweep.amounts'           => $amounts_original,
        'payments.crypto.internal_sweep.fee_rate_percent'  => $fee_rate_percent_original,
        'payments.crypto.internal_sweep.fee_limit_percent' => $fee_limit_percent_original,
    });
};

$mock_app_config->unmock_all();

done_testing();
