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

use BOM::Test::RPC::Client;
use BOM::RPC::v3::MarketData;
use Email::Stuffer::TestLinks;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

my ($base, $result);
subtest 'invalid currency' => sub {
    $base = 'XXX';
    $result = $c->call_ok('exchange_rates', {args => {base_currency => $base}});
    ok $result->has_no_system_error->has_error, 'RPC called without system errors';
    ok $result->error_code_is('InvalidCurrency'), 'Base currency not available';
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
done_testing();
