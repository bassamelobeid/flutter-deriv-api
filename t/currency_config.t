use strict;
use warnings;

use Test::More;
use Test::MockModule;
use JSON::MaybeUTF8;

use BOM::Config::CurrencyConfig;
use BOM::Config::Runtime;

my %fake_config;

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
    });

subtest 'transfer_between_accounts_limits' => sub {
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
    });

    my @all_currencies  = LandingCompany::Registry::all_currencies();
    my $transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();

    foreach (@all_currencies) {
        my $type = LandingCompany::Registry::get_currency_type($_);
        my $min_default = ($type eq 'crypto') ? 9 : 90;

        cmp_ok($transfer_limits->{$_}->{min}, '==', $minimum->{$_} // $min_default, "Transfer between account minimum is correct for $_");
    }
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
        'payments.transfer_between_accounts.exchange_rate_expiry.fiat'   => 8600,
        'payments.transfer_between_accounts.exchange_rate_expiry.crypto' => 1800,
    });

    is(BOM::Config::CurrencyConfig::rate_expiry('USD', 'EUR'), 8600, 'should return fiat expiry if all currencies are fiat');
    is(BOM::Config::CurrencyConfig::rate_expiry('BTC', 'ETH'), 1800, 'should return crypto expiry if all currencies are crypto');
    is(BOM::Config::CurrencyConfig::rate_expiry('BTC', 'USD'), 1800, 'should return crypto expiry if crypto expiry is less than fiat expiry');

    $app_config->set({'payments.transfer_between_accounts.exchange_rate_expiry.fiat' => 5});

    is(BOM::Config::CurrencyConfig::rate_expiry('BTC', 'USD'), 5, 'should return fiat expiry if fiat expiry is less than crypto expiry');

};

$mock_app_config->unmock_all();

done_testing();
