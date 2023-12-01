#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Exception;
use Test::MockModule;
use Test::Warnings;
use Format::Util::Numbers qw(formatnumber);

use Quant::Framework::EconomicEventCalendar;
use BOM::Test::Data::Utility::UnitTestMarketData;
use Try::Tiny;
use BOM::Config::Chronicle;
use BOM::Test::RPC::QueueClient;
use BOM::RPC::v3::MarketData;
use Email::Stuffer::TestLinks;

my $c = BOM::Test::RPC::QueueClient->new();

my ($base, $result);
subtest 'invalid currency' => sub {
    $base = 'INVALID';
    $c->call_ok('exchange_rates', {args => {base_currency => $base}})
        ->has_no_system_error->has_error->error_code_is('InvalidCurrency', 'Returns correct error code if currency is invalid')
        ->error_message_is('The provided currency INVALID is invalid.', 'Returns correct error message if currency is invalid');
};

subtest 'exchange rates' => sub {
    $base = 'USD';
    my $target_currency          = 'BTC';
    my $mocked_CurrencyConverter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
    $mocked_CurrencyConverter->mock(
        'in_usd',
        sub {
            my $price         = shift;
            my $from_currency = shift;

            $from_currency eq 'AUD' and return 0.90 * $price;
            $from_currency eq 'ETH' and return 500 * $price;
            $from_currency eq 'LTC' and return 120 * $price;
            $from_currency eq 'EUR' and return 1.18 * $price;
            $from_currency eq 'GBP' and return 1.3333 * $price;
            $from_currency eq 'JPY' and return 0.0089 * $price;
            $from_currency eq 'BTC' and return 5500 * $price;
            $from_currency eq 'USD' and return 1 * $price;
            return 0;
        });

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency   => $base,
                target_currency => $target_currency,
                subscribe       => 1
            }})->has_no_system_error->has_no_error->result;

    ok $result->{date},                                               "Date tag";
    ok $result->{base_currency} && $base eq $result->{base_currency}, "Base currency";
    ok $result->{rates},                                              "Rates tag";
    ok(exists $result->{rates}->{$target_currency}, "Target currency rate is provided");
    is(scalar keys %{$result->{rates}}, 1, "Only 1 exchange rate provided");
    cmp_ok($result->{rates}->{BTC}, '==', 1 / 5500, 'correct rate for BTC');

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency   => $base,
                target_currency => $target_currency,
            }})->has_no_system_error->has_no_error->result;

    ok $result->{date},                                               "Date tag";
    ok $result->{base_currency} && $base eq $result->{base_currency}, "Base currency";
    ok $result->{rates},                                              "Rates tag";
    ok(exists $result->{rates}->{$target_currency}, "Target currency rate is provided");
    is(scalar keys %{$result->{rates}}, 1, "Only 1 exchange rate provided");
    cmp_ok($result->{rates}->{BTC}, '==', 1 / 5500, 'correct rate for BTC');

    $result = $c->call_ok('exchange_rates', {args => {base_currency => $base}})->has_no_system_error->has_no_error->result;

    ok $result->{date},                                               "Date tag";
    ok $result->{base_currency} && $base eq $result->{base_currency}, "Base currency";
    ok $result->{rates},                                              "Rates tag";
    is(scalar keys %{$result->{rates}}, 7, "All 7 exchange rates are provided");

    my @expected_currencies = ('AUD', 'BTC', 'ETH', 'EUR', 'GBP', 'JPY', 'LTC');
    my @actual_currencies   = sort (keys %{$result->{rates}});

    is_deeply(\@actual_currencies, \@expected_currencies, 'Currency pairs with USD');
    cmp_ok($result->{rates}->{AUD}, '==', 1 / 0.9,    'correct rate for AUD');
    cmp_ok($result->{rates}->{BTC}, '==', 1 / 5500,   'correct rate for BTC');
    cmp_ok($result->{rates}->{ETH}, '==', 1 / 500,    'correct rate for ETH');
    cmp_ok($result->{rates}->{EUR}, '==', 1 / 1.18,   'correct rate for EUR');
    cmp_ok($result->{rates}->{GBP}, '==', 1 / 1.3333, 'correct rate for GBP');
    cmp_ok($result->{rates}->{JPY}, '==', 1 / 0.0089, 'correct rate for JPY');
    cmp_ok($result->{rates}->{LTC}, '==', 1 / 120,    'correct rate for LTC');

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency => $base,
                subscribe     => 1
            }}
    )->has_no_system_error->has_error->error_code_is('MissingRequiredParams', 'Returns correct error code if target currency arg is not passed')
        ->error_message_is('Target currency is required.');

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency   => $base,
                target_currency => 'INVALID',
                subscribe       => 1
            }}
    )->has_no_system_error->has_error->error_code_is('ExchangeRatesNotAvailable', 'Returns correct error code if currency pair does not exist')
        ->error_message_is('Exchange rates are not currently available.');

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency   => $base,
                target_currency => 'INVALID',
            }}
    )->has_no_system_error->has_error->error_code_is('ExchangeRatesNotAvailable', 'Returns correct error code if currency pair does not exist')
        ->error_message_is('Exchange rates are not currently available.');

};

subtest 'economic_calendar' => sub {

    my $today = Date::Utility->new()->truncate_to_day();
    my $start = $today->minus_time_interval("1d");
    my $end   = $today->plus_time_interval("1d");

    my $chronicle_writer = BOM::Config::Chronicle::get_chronicle_writer();

    $chronicle_writer->set(
        'economic_events',
        'ECONOMIC_EVENTS_CALENDAR',
        [{
                symbol       => 'USD',
                release_date => $today->plus_time_interval("1h")->epoch,
                impact       => "1",
                forecast     => "49.6",
                source       => 'forexfactory',
                event_name   => 'Final Manufacturing PMI',
            },
            {
                symbol       => 'JPY',
                release_date => $today->plus_time_interval("2d")->epoch,
                impact       => "2",
                forecast     => "-31",
                source       => 'bloomberg',
                event_name   => 'Tankan Manufacturing Index',
            }
        ],
        Date::Utility->new,
        0, 86400
    );

    $result = $c->call_ok(
        'economic_calendar',
        {
            args => {
                "start_date" => $start->epoch(),
                "end_date"   => $end->epoch()}});

    ok $result->has_no_system_error->has_no_error, 'RPC called without system errors';

    my %expected = (
        'release_date' => 1594170000,
        'forecast'     => '49.6',
        'impact'       => '1',
        'currency'     => 'USD',
        'event_name'   => 'Final Manufacturing PMI'
    );

    cmp_ok(scalar @{$result->response->result->{events}}, '==', 1, 'Correct number of events is returned');

    $start  = $today->plus_time_interval("1d");
    $end    = $today->minus_time_interval("1d");
    $result = $c->call_ok(
        'economic_calendar',
        {
            args => {
                "start_date" => $start->epoch(),
                "end_date"   => $end->epoch()}});

    ok $result->error_code_is('InputValidationFailed'), 'Must not be earlier than start_date';

    $start  = $today->minus_time_interval("30d");
    $end    = $today->plus_time_interval("1d");
    $result = $c->call_ok(
        'economic_calendar',
        {
            args => {
                "start_date" => $start->epoch(),
                "end_date"   => $end->epoch()}});

    ok $result->error_code_is('InputValidationFailed'), 'Start date should not exceed 14 days in the past from now';

    $start  = $today->minus_time_interval("1d");
    $end    = $today->plus_time_interval("30d");
    $result = $c->call_ok(
        'economic_calendar',
        {
            args => {
                "start_date" => $start->epoch(),
                "end_date"   => $end->epoch()}});

    ok $result->error_code_is('InputValidationFailed'), 'End date should not exceed 15 days in the future from now';
};

done_testing();
