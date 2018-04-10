#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::Exception;
use BOM::Test::RPC::Client;
use Test::MockModule;
use LandingCompany::Registry;
use BOM::RPC::v3::MarketData;
use Format::Util::Numbers qw(formatnumber);

my $base = 'USD';

sub checkResultStructure {
    my $result = shift;
    ok $result->{date}, "Date tag";
    ok $result->{base} && $base eq $result->{base}, "Base currency";
    ok $result->{rates}, 'Rates tag';
    if (exists $result->{rates}) {
        ok(!exists $result->{rates}->{$base}, "Base currency not included in rates");
    }
}

note("exchange_rates PRC call normally (expectedly with an empty data set).");
my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
my $result = $c->call_ok('exchange_rates');
ok $result->has_no_system_error, 'RPC called without system errors';
if ($result->has_error) {
    ok $result->error_code_is('NoExRates'), 'Proper error code';
} else {
    checkResultStructure($result->result);
}

note("exchange_rates RPC call with a custom data set.");
my @all_currencies = LandingCompany::Registry->new()->all_currencies;
cmp_ok($#all_currencies, ">", 1, "At least two currencies available");
ok grep ($_ eq $base, @all_currencies), 'USD is included in currencies';
#let the first currency in the list be something other than the base
if ($all_currencies[0] eq $base) {
    @all_currencies[0, 1] = @all_currencies[1, 0];
}

# setting rates experimentally to indices (except the excluded first currency)
my %rates;
for my $i (0 .. $#all_currencies) {
    $rates{$all_currencies[$i]} = $i;
}

my $mocked_in_USD = Test::MockModule->new('BOM::RPC::v3::MarketData');
$mocked_in_USD->mock(
    'in_USD' => sub {
        my ($amount, $currency) = @_;
        return ($amount * $rates{$currency}) // 0;
    });

$result = BOM::RPC::v3::MarketData::exchange_rates();
checkResultStructure($result);
foreach my $cur (keys %{$result->{rates}}) {
    ok(formatnumber('price', $cur, 1.0 / $rates{$cur}) == $result->{rates}->{$cur}, "$cur exchange rate calculation.");
}
# first currency should have been excluded by _exchange_rates function because its rate (index) is 0
my $excluded = $all_currencies[0];
ok(!exists $result->{rates}->{$excluded}, 'First currency is excluded from this test.');

done_testing();
