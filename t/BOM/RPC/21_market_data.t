#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::Exception;
use BOM::Test::RPC::Client;
use Test::MockModule;
use LandingCompany::Registry;

use BOM::RPC::v3::MarketData qw(exchange_rates convert_to_USD);

sub checkResultStructure {
    my $result = shift;
    ok $result->{date}, "Date tag";
    ok ("USD" eq $result->{base}), "Base currency";
    ok $result->{rates}, 'Rates tag';
    if ($result->{rates}){
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

# Mocked currency converter to imitate currency conversion
my $mocked_CurrencyConverter = Test::MockModule->new('BOM::RPC::v3::MarketData', no_auto => 1);
$mocked_CurrencyConverter->mock(
    'convert_to_USD',
    sub {
        diag("FFFFFFFFFFFFFF");
        my $from_currency = shift;

        #excluding EUR just for test
        # $from_currency eq 'EUR' and return 1.1888;
        $from_currency eq 'GBP' and return 2;
        $from_currency eq 'JPY' and return 0.0089;
        $from_currency eq 'BTC' and return 5500;
        $from_currency eq 'USD' and return 1;
        return 0;
    });
    
my $result = BOM::RPC::v3::MarketData::exchange_rates();

my @all_currencies = LandingCompany::Registry->new()->all_currencies;
cmp_ok($#all_currencies, ">", 1, "At least two currencies available");

diag("Convert to GBP to USD: ". BOM::RPC::v3::MarketData::convert_to_USD('GBP'));

checkResultStructure($result);
if ($result->{rates}){
    is $result->{rates}->{"GBP"}, 0.5, 'Correct exchange rate for GBP'; 
    not ok $result->{rates}->{"EUR"}, 'EUR is excluded in this test .';
}


done_testing();
