use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Data::Dumper;

use BOM::Config::CurrencyConfig;
use LandingCompany::Registry;
my $currency_config_mock = Test::MockModule->new("BOM::Config::CurrencyConfig", no_auto => 1);

subtest 'is_crypto_currency_suspended' => sub {
    my $expected;
    my $mock_currency;
    my $mocked_currency_validity;
    my $mocked_suspended_currency;
    $currency_config_mock->redefine("is_valid_crypto_currency",        sub { return $mocked_currency_validity });
    $currency_config_mock->redefine("get_suspended_crypto_currencies", sub { return $mocked_suspended_currency });

    $expected = "Expected currency code parameter.";
    throws_ok { BOM::Config::CurrencyConfig::is_crypto_currency_suspended() } qr/$expected/, "No currency code parameter is specified";

    $mock_currency            = "ABC";
    $mocked_currency_validity = 0;
    $expected                 = "Failed to accept $mock_currency as a cryptocurrency.";
    throws_ok { BOM::Config::CurrencyConfig::is_crypto_currency_suspended($mock_currency) } qr/$expected/, "Invalid cryptocurrency is specified";

    $mock_currency             = "UST";
    $mocked_currency_validity  = 1;
    $mocked_suspended_currency = {
        "UST" => {},
        "BTC" => {},
        "ETH" => {}};
    $expected = 1;
    is(BOM::Config::CurrencyConfig::is_crypto_currency_suspended($mock_currency),
        $expected, "Valid crypto currency that is not suspended is specified");

    $mock_currency             = "SOL";
    $mocked_currency_validity  = 1;
    $mocked_suspended_currency = {
        "UST" => {},
        "BTC" => {},
        "ETH" => {}};
    $expected = 0;
    is(BOM::Config::CurrencyConfig::is_crypto_currency_suspended($mock_currency), $expected, "Valid but suspended crypto currency is specified");
    $currency_config_mock->unmock_all();
};

subtest 'platform_transfer_limits' => sub {
    my $mocked_brand_platform_limt;
    my @mocked_all_currencies;
    my $expected;
    my $mocked_converted_currency;
    my $registry_mock = Test::MockModule->new("LandingCompany::Registry");
    $registry_mock->redefine("all_currencies" => sub { return @mocked_all_currencies; });
    $currency_config_mock->redefine(
        "convert_currency" => sub {
            my ($amt, $currency, $tocurrency, $seconds) = @_;
            return $amt if $amt == 0 or $currency eq $tocurrency;
            return 2 * $amt;
        });
    $currency_config_mock->redefine(
        "financialrounding" => sub {
            my $amt = $_[2];
            return 1.1 * $amt;
        });
    $currency_config_mock->redefine("get_platform_transfer_limit_by_brand" => sub { return $mocked_brand_platform_limt; });
    @mocked_all_currencies      = ("USD", "INR");
    $mocked_brand_platform_limt = {
        minimum => {
            amount   => 5,
            currency => "USD"
        },
        maximum => {
            amount   => 1000,
            currency => "USD"
        }};
    $expected = {
        "USD" => {
            min => 5.5,
            max => 1100
        },
        "INR" => {
            min => 11,
            max => 2200
        }};
    is_deeply(BOM::Config::CurrencyConfig::platform_transfer_limits(), $expected, "Platform limits are specified in a single currency");

    @mocked_all_currencies      = ("USD", "INR", "MYR");
    $mocked_brand_platform_limt = {
        minimum => {
            amount   => 5,
            currency => "INR"
        },
        maximum => {
            amount   => 1000,
            currency => "USD"
        }};
    $expected = {
        "USD" => {
            min => 11,
            max => 1100
        },
        "INR" => {
            min => 5.5,
            max => 2200
        },
        "MYR" => {
            min => 11,
            max => 2200
        }};
    is_deeply(BOM::Config::CurrencyConfig::platform_transfer_limits(), $expected, "Platform limits are specified in different currencies");

    @mocked_all_currencies = ();
    $expected              = {};
    is_deeply(BOM::Config::CurrencyConfig::platform_transfer_limits(), $expected, "There are no currencies");

    $currency_config_mock->unmock_all();
};

done_testing;
