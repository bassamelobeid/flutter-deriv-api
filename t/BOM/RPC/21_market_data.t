#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Exception;
use Test::MockModule;
use Test::Warnings;
use Format::Util::Numbers qw(formatnumber);

use LandingCompany::Registry;

use Quant::Framework::EconomicEventCalendar;
use BOM::Test::Data::Utility::UnitTestMarketData;
use Try::Tiny;
use BOM::Config::Chronicle;

use BOM::Test::RPC::Client;
use BOM::RPC::v3::MarketData;
use Email::Stuffer::TestLinks;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

my ($base, $result);
subtest 'invalid currency' => sub {
    $base = 'INVALID';
    $c->call_ok('exchange_rates', {args => {base_currency => $base}})
        ->has_no_system_error->has_error->error_code_is('InvalidCurrency', 'Returns correct error code if currency is invalid')
        ->error_message_is('The provided currency INVALID is invalid.', 'Returns correct error message if currency is invalid');
};

subtest 'exchange rates' => sub {
    $base = 'USD';
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

    $result = $c->call_ok('exchange_rates', {args => {base_currency => $base}})->has_no_system_error->has_no_error->result;

    ok $result->{date}, "Date tag";
    ok $result->{base_currency} && $base eq $result->{base_currency}, "Base currency";
    ok $result->{rates}, 'Rates tag';
    if (exists $result->{rates}) {
        ok(!exists $result->{rates}->{$base}, "Base currency not included in rates");
    }
    cmp_ok($result->{rates}->{LTC}, '==', 0.00833333, 'correct rate for LTC');
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
