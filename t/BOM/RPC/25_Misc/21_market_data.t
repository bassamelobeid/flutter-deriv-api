#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Config::Chronicle;
use BOM::Test::Data::Utility::UnitTestMarketData;
use BOM::Test::RPC::QueueClient;
use BOM::RPC::v3::MarketData;
use Email::Stuffer::TestLinks;
use Format::Util::Numbers qw(roundnear);
use Quant::Framework::EconomicEventCalendar;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Test::Mojo;
use Test::More;
use Test::Warnings;
use Try::Tiny;

my $base_currency = 'USD';
my $c             = BOM::Test::RPC::QueueClient->new();
my $result;

subtest 'invalid currency' => sub {
    my $invalid_currency = 'INVALID';
    my %error            = (
        'error_code'    => 'InvalidCurrency',
        'error_message' => 'The provided currency INVALID is invalid.'
    );

    $c->call_ok('exchange_rates', {args => {base_currency => $invalid_currency}})
        ->has_no_system_error->has_error->error_code_is($error{error_code}, 'Returns correct error code if base currency is invalid')
        ->error_message_is($error{error_message}, 'Returns correct error message if base currency is invalid');

    $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency   => $base_currency,
                target_currency => $invalid_currency,
            }}
    )->has_no_system_error->has_error->error_code_is($error{error_code}, 'Returns correct error code if target currency is invalid')
        ->error_message_is($error{error_message}, 'Returns correct error message if target currency is invalid');
};

subtest 'missing required params' => sub {
    my %error = (
        'error_code'    => 'MissingRequiredParams',
        'error_message' => 'Target currency is required.'
    );

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency => $base_currency,
                subscribe     => 1
            }})
        ->has_no_system_error->has_error->error_code_is($error{error_code},
        'Returns correct error code if target currency is not passed when subscribing')
        ->error_message_is($error{error_message}, 'Returns correct error message if target currency is not passed when subscribing');

    $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency  => $base_currency,
                include_spread => 1
            }})
        ->has_no_system_error->has_error->error_code_is($error{error_code},
        'Returns correct error code if target currency is not passed when spread is requested')
        ->error_message_is($error{error_message}, 'Returns correct error message if target currency is not passed when spread is requested');
};

subtest 'exchange rates' => sub {
    my $target_currency = 'BTC';
    my %spread_dataset  = ('exchange_rates_spread::BTC/USD' => '2.424');
    my %expected_result = (
        "spot_rate" => roundnear(0.000001, 1 / 5500),
        "ask_rate"  => roundnear(0.000001, 1 / (5500 - (2.424 / 2))),
        "bid_rate"  => roundnear(0.000001, 1 / (5500 + (2.424 / 2))),
    );

    my $mocked_CurrencyConverter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
    my $mock_redis               = Test::MockModule->new('RedisDB');

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
    $mock_redis->mock('get', sub { my ($self, $key) = @_; return $spread_dataset{$key} });

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency   => $base_currency,
                target_currency => $target_currency,
            }})->has_no_system_error->has_no_error->result;

    ok $result->{date},                                                        "Date tag";
    ok $result->{base_currency} && $base_currency eq $result->{base_currency}, "Base currency";
    ok $result->{rates},                                                       "Rates tag";
    ok(exists $result->{rates}->{$target_currency}, "Target currency rate is provided");
    is(scalar keys %{$result->{rates}}, 1, "Only 1 exchange rate provided");
    cmp_ok($result->{rates}->{BTC}, '==', 1 / 5500, 'correct rate for BTC');

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency   => $base_currency,
                target_currency => $target_currency,
                include_spread  => 1
            }})->has_no_system_error->has_no_error->result;

    ok $result->{date},                                                        "Date tag";
    ok $result->{base_currency} && $base_currency eq $result->{base_currency}, "Base currency";
    ok $result->{rates}->{$target_currency}->{spot_rate},                      "Spot rate tag";
    ok $result->{rates}->{$target_currency}->{ask_rate},                       "Ask rate tag";
    ok $result->{rates}->{$target_currency}->{bid_rate},                       "Bid rate tag";
    ok(exists $result->{rates}->{$target_currency}, "Target currency rate is provided");

    is(scalar keys %{$result->{rates}}, 1, "Only 1 exchange rate provided");
    cmp_ok(roundnear(0.000001, $result->{rates}->{BTC}->{spot_rate}), '==', $expected_result{spot_rate}, 'correct spot rate for USD_BTC');
    cmp_ok(roundnear(0.000001, $result->{rates}->{BTC}->{ask_rate}),  '==', $expected_result{ask_rate},  'correct ask rate for USD_BTC');
    cmp_ok(roundnear(0.000001, $result->{rates}->{BTC}->{bid_rate}),  '==', $expected_result{bid_rate},  'correct bid rate for USD_BTC');

    $result = $c->call_ok('exchange_rates', {args => {base_currency => $base_currency}})->has_no_system_error->has_no_error->result;

    ok $result->{date},                                                        "Date tag";
    ok $result->{base_currency} && $base_currency eq $result->{base_currency}, "Base currency";
    ok $result->{rates},                                                       "Rates tag";
    is(scalar keys %{$result->{rates}}, 7, "All 7 exchange rates are provided");

    my @expected_currencies = ('AUD', 'BTC', 'ETH', 'EUR', 'GBP', 'JPY', 'LTC');
    my @actual_currencies   = sort (keys %{$result->{rates}});

    is_deeply(\@actual_currencies, \@expected_currencies, 'Currency pairs with USD');
    cmp_ok($result->{rates}->{AUD}, '==', 1 / 0.9,    'correct rate for USD_AUD');
    cmp_ok($result->{rates}->{BTC}, '==', 1 / 5500,   'correct rate for USD_BTC');
    cmp_ok($result->{rates}->{ETH}, '==', 1 / 500,    'correct rate for USD_ETH');
    cmp_ok($result->{rates}->{EUR}, '==', 1 / 1.18,   'correct rate for USD_EUR');
    cmp_ok($result->{rates}->{GBP}, '==', 1 / 1.3333, 'correct rate for USD_GBP');
    cmp_ok($result->{rates}->{JPY}, '==', 1 / 0.0089, 'correct rate for USD_JPY');
    cmp_ok($result->{rates}->{LTC}, '==', 1 / 120,    'correct rate for USD_LTC');
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
