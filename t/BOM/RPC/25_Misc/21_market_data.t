#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Config::Chronicle;
use BOM::RPC::v3::MarketData;
use BOM::Test::Data::Utility::UnitTestMarketData;
use BOM::Test::RPC::QueueClient;
use Email::Stuffer::TestLinks;
use Format::Util::Numbers qw(roundnear);
use Quant::Framework::EconomicEventCalendar;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Test::Mojo;
use Test::More;
use Test::Warnings;

my $mock_currency_converter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
$mock_currency_converter->mock(
    in_usd => sub {
        my ($amount, $from_currency) = @_;

        # Official currencies are currencies that are offered in LandingCompany::Registry->all_currencies
        # We still use unofficial currencies in P2P
        my %spot_rate = (
            AUD => 0.90,
            BTC => 5500,
            ETH => 500,
            EUR => 1.18,
            GBP => 1.3333,
            IDR => 0.000062,    # unofficial
            INR => 0.012,       # unofficial
            JPY => 0.0089,      # unofficial
            LTC => 120,
            NZD => 0.6,         # unofficial
            USD => 1
        );

        return $spot_rate{$from_currency} * $amount if $spot_rate{$from_currency};

        die "Throw error if no rate is available";
    },
);

my $base_currency = 'USD';
my $c             = BOM::Test::RPC::QueueClient->new();
my %errors        = (
    ExchangeRatesNotAvailable => 'Exchange rates are not currently available.',
    InvalidCurrency           => 'The provided currency INVALID is invalid.',
    InvalidCurrencyNZD        => 'The provided currency NZD is invalid.',
    MissingRequiredParams     => 'Target currency is required.',
);

my $result;
my %expected_results = (
    AUD => 1 / 0.9,
    BTC => 1 / 5500,
    ETH => 1 / 500,
    EUR => 1 / 1.18,
    GBP => 1 / 1.3333,
    IDR => 1 / 0.000062,
    INR => 1 / 0.012,
    JPY => 1 / 0.0089,
    LTC => 1 / 120,
    NZD => 1 / 0.6
);

subtest 'unofficial and invalid currency' => sub {
    my $unofficial_currency = 'NZD';
    my $invalid_currency    = 'INVALID';

    $result = $c->call_ok('exchange_rates', {args => {base_currency => $invalid_currency}})->has_no_system_error;
    ok $result->error_code_is('InvalidCurrency'),           'Throw InvalidCurrency if base currency is invalid';
    ok $result->error_message_is($errors{InvalidCurrency}), 'Returns correct error message if base currency is invalid';

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency   => $base_currency,
                target_currency => $invalid_currency,
            },
        })->has_no_system_error;
    ok $result->error_code_is('ExchangeRatesNotAvailable'),           'Throw ExchangeRatesNotAvailable if target currency is invalid';
    ok $result->error_message_is($errors{ExchangeRatesNotAvailable}), 'Returns correct error message if target currency is invalid';

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency   => $base_currency,
                target_currency => $unofficial_currency,
            },
        })->has_no_system_error->has_no_error->result;
    ok(exists $result->{rates}->{$unofficial_currency}, "Currency rate is provided if target currency is unofficial currency");
    is(scalar keys %{$result->{rates}}, 1, "Only 1 exchange rate provided");
    cmp_ok($result->{rates}->{$unofficial_currency}, '==', $expected_results{$unofficial_currency}, 'Correct rate for NZD');

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency   => $base_currency,
                target_currency => $invalid_currency,
                include_spread  => 1,
            },
        })->has_no_system_error;
    ok $result->error_code_is('InvalidCurrency'),           'Throw InvalidCurrency if target currency is invalid and spread is requested';
    ok $result->error_message_is($errors{InvalidCurrency}), 'Returns correct error message if target currency is invalid and spread is requested';

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency   => $base_currency,
                target_currency => $unofficial_currency,
                include_spread  => 1,
            },
        })->has_no_system_error;
    ok $result->error_code_is('InvalidCurrency'), 'Throw InvalidCurrency if target currency is unofficial currency and spread is requested';
    ok $result->error_message_is($errors{InvalidCurrencyNZD}),
        'Returns correct error message if target currency is unofficial currency and spread is requested';
};

subtest 'missing required params' => sub {
    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency => $base_currency,
                subscribe     => 1
            },
        })->has_no_system_error;
    ok $result->error_code_is('MissingRequiredParams'),           'Throw MissingRequiredParams if target currency is not passed when subscribing';
    ok $result->error_message_is($errors{MissingRequiredParams}), 'Returns correct error message if target currency is not passed when subscribing';

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency  => $base_currency,
                include_spread => 1
            },
        })->has_no_system_error;
    ok $result->error_code_is('MissingRequiredParams'), 'Throw MissingRequiredParams if target currency is not passed when spread is requested';
    ok $result->error_message_is($errors{MissingRequiredParams},
        'Returns correct error message if target currency is not passed when spread is requested');
};

subtest 'exchange rates' => sub {
    my $target_currency = 'BTC';
    my %spread_dataset  = ('exchange_rates_spread::BTC/USD' => '2.424');

    my $mock_redis = Test::MockModule->new('RedisDB');
    $mock_redis->mock('get', sub { my ($self, $key) = @_; return $spread_dataset{$key} });

    my %expected_rate = (
        "spot_rate" => roundnear(0.000001, 1 / 5500),
        "ask_rate"  => roundnear(0.000001, 1 / (5500 - (2.424 / 2))),
        "bid_rate"  => roundnear(0.000001, 1 / (5500 + (2.424 / 2))),
    );

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency   => $base_currency,
                target_currency => $target_currency,
            },
        })->has_no_system_error->has_no_error->result;

    ok $result->{date},                                                        "Date tag";
    ok $result->{base_currency} && $base_currency eq $result->{base_currency}, "Base currency";
    ok $result->{rates},                                                       "Rates tag";
    ok(exists $result->{rates}->{$target_currency}, "Target currency rate is provided");
    is(scalar keys %{$result->{rates}}, 1, "Only 1 exchange rate provided");
    cmp_ok($result->{rates}->{$target_currency}, '==', $expected_results{$target_currency}, 'correct rate for BTC');

    $result = $c->call_ok(
        'exchange_rates',
        {
            args => {
                base_currency   => $base_currency,
                target_currency => $target_currency,
                include_spread  => 1
            },
        })->has_no_system_error->has_no_error->result;

    ok $result->{date},                                                        "Date tag";
    ok $result->{base_currency} && $base_currency eq $result->{base_currency}, "Base currency";
    ok $result->{rates}->{$target_currency}->{spot_rate},                      "Spot rate tag";
    ok $result->{rates}->{$target_currency}->{ask_rate},                       "Ask rate tag";
    ok $result->{rates}->{$target_currency}->{bid_rate},                       "Bid rate tag";
    ok(exists $result->{rates}->{$target_currency}, "Target currency rate is provided");
    is(scalar keys %{$result->{rates}}, 1, "Only 1 exchange rate provided");
    cmp_ok(roundnear(0.000001, $result->{rates}->{$target_currency}->{spot_rate}), '==', $expected_rate{spot_rate}, 'correct spot rate for USD_BTC');
    cmp_ok(roundnear(0.000001, $result->{rates}->{$target_currency}->{ask_rate}),  '==', $expected_rate{ask_rate},  'correct ask rate for USD_BTC');
    cmp_ok(roundnear(0.000001, $result->{rates}->{$target_currency}->{bid_rate}),  '==', $expected_rate{bid_rate},  'correct bid rate for USD_BTC');

    $result = $c->call_ok('exchange_rates', {args => {base_currency => $base_currency}})->has_no_system_error->has_no_error->result;

    ok $result->{date},                                                        "Date tag";
    ok $result->{base_currency} && $base_currency eq $result->{base_currency}, "Base currency";
    ok $result->{rates},                                                       "Rates tag";
    is(scalar keys %{$result->{rates}}, 10, "All 10 exchange rates are provided");

    my @actual_currencies = sort (keys %{$result->{rates}});
    is_deeply(\@actual_currencies, [sort keys %expected_results], 'Currency pairs with USD');
    foreach my $currency (@actual_currencies) {
        cmp_ok($result->{rates}->{$currency}, '==', $expected_results{$currency}, "correct rate for USD_$currency");
    }
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
                "end_date"   => $end->epoch(),
            },
        });

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
                "end_date"   => $end->epoch(),
            },
        });

    ok $result->error_code_is('InputValidationFailed'), 'Must not be earlier than start_date';

    $start  = $today->minus_time_interval("30d");
    $end    = $today->plus_time_interval("1d");
    $result = $c->call_ok(
        'economic_calendar',
        {
            args => {
                "start_date" => $start->epoch(),
                "end_date"   => $end->epoch(),
            },
        });

    ok $result->error_code_is('InputValidationFailed'), 'Start date should not exceed 14 days in the past from now';

    $start  = $today->minus_time_interval("1d");
    $end    = $today->plus_time_interval("30d");
    $result = $c->call_ok(
        'economic_calendar',
        {
            args => {
                "start_date" => $start->epoch(),
                "end_date"   => $end->epoch(),
            },
        });

    ok $result->error_code_is('InputValidationFailed'), 'End date should not exceed 15 days in the future from now';
};

done_testing();
