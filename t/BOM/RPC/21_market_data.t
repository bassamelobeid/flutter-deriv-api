#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::Exception;
use BOM::Test::RPC::Client;
use Test::MockModule;
use LandingCompany::Registry;
#use Postgres::FeedDB::CurrencyConverter qw(in_USD);
use BOM::RPC::v3::MarketData;

sub checkResultStructure {
    my $result = shift;
    ok $result->{date}, "Date tag";
    ok $result->{base} && "USD" eq $result->{base}, "Base currency";
    ok $result->{rates}, 'Rates tag';
    if ($result->{rates}) {
        not ok $result->{rates}->{'USD'}, 'Base currency should not be included in rates';
    }
}

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
diag("Testing exchange_rates PRC call.");

my $firstCall = $c->call_ok('exchange_rates');

ok $firstCall->has_no_system_error, 'RPC called without system errors';
if ($firstCall->has_error) {
    ok $firstCall->error_code_is('NoExRates'), 'Proper error code';
} else {
    checkResultStructure($firstCall->result);
}

diag("Testing exchange_rates function call.");

my @all_currencies = LandingCompany::Registry->new()->all_currencies;
cmp_ok($#all_currencies, ">", 1, "At least two currencies available");

=head regular mock (failed)
# Regular mocking (Fails when i call _exchage_rates)
my $mocked_CurrencyConverter = Test::MockModule->new('BOM::RPC::v3::MarketData');
$mocked_CurrencyConverter->mock(
    'to_USD' => sub {
        diag("FFFFFFFFFFFFFF");
        my $value         = shift;
        my $from_currency = shift;

        #excluding EUR just for test
        # $from_currency eq 'EUR' and return 1.1888;
        $from_currency eq 'GBP' and return 2;
        $from_currency eq 'JPY' and return 0.0089;
        $from_currency eq 'BTC' and return 5500;
        $from_currency eq 'USD' and return 1;
        return 0;
    });
=cut

# Alternative mocking (fails the same way)
local *BOM::RPC::v3::MarketData::to_USD = sub {
    my $value         = shift;
    my $from_currency = shift;

    #excluding EUR just for test
    # $from_currency eq 'EUR' and return 1.1888;
    $from_currency eq 'GBP' and return 2;
    $from_currency eq 'JPY' and return 0.0089;
    $from_currency eq 'BTC' and return 5500;
    $from_currency eq 'USD' and return 1;
    return 0;
};

# _excnage_rates still calls original to_USD
my $result = BOM::RPC::v3::MarketData::_exchange_rates();

#
diag("Convert GBP to USD: " . BOM::RPC::v3::MarketData::to_USD(1, 'GBP'));

checkResultStructure($result);
if ($result->{rates}) {
    is $result->{rates}->{"GBP"}, 0.5, 'Correct exchange rate for GBP';
    #not ok $result->{rates}->{"EUR"}, 'EUR is excluded in this test .';
}

done_testing();
