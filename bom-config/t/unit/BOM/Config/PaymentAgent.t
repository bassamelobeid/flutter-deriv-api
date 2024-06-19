use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;

use BOM::Config::PaymentAgent;

subtest 'get_transfer_min_max' => sub {
    my $mock_currency_type;
    my $mock_payment_agent;
    my $expected;
    my $test_currency;
    my $mocked_lc_registry = Test::MockModule->new("LandingCompany::Registry");
    my $mocked_bom_config  = Test::MockModule->new("BOM::Config");
    $mocked_lc_registry->redefine("get_currency_type", sub { return $mock_currency_type });
    $mocked_bom_config->redefine("payment_agent", sub { return $mock_payment_agent });

    $expected = 'No currency is specified for PA limits';
    throws_ok { BOM::Config::PaymentAgent::get_transfer_min_max() } qr/$expected/, "No currency is specified";

    $test_currency      = 'USD';
    $expected           = "Invalid currency $test_currency for PA limits";
    $mock_currency_type = 0;
    throws_ok { BOM::Config::PaymentAgent::get_transfer_min_max($test_currency) } qr/$expected/, "Invalid currency type is specfied";

    $mock_payment_agent = {
        payment_limits => {
            fiat => {
                minimum => 10,
                maximum => 1000
            },
            crypto => {
                minimum => 0.002,
                maximum => 5
            }
        },
        currency_specific_limits => {
            UST => {
                minimum => 10,
                maximum => 2000
            }}};
    $mock_currency_type = 'crypto';
    $test_currency      = 'UST';
    $expected           = $mock_payment_agent->{currency_specific_limits}->{$test_currency};
    is_deeply(BOM::Config::PaymentAgent::get_transfer_min_max($test_currency), $expected, "valid currency and currency type is specified");

    $mock_currency_type = 'fiat';
    $test_currency      = 'EUR';
    $expected           = $mock_payment_agent->{payment_limits}->{$mock_currency_type};
    is_deeply(BOM::Config::PaymentAgent::get_transfer_min_max($test_currency), $expected, "valid currency type and invalid currency is specified");

    $mock_currency_type = 'not a valid type';
    $test_currency      = 'not a valid currency';
    $expected           = undef;
    is_deeply(BOM::Config::PaymentAgent::get_transfer_min_max($test_currency), $expected, "Both currency and currency type specified are invalid");
};

done_testing;
