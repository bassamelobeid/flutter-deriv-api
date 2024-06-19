use strict;
use warnings;
use Test::More;

use BOM::RiskReporting::Dashboard;
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase          qw(:init);
use BOM::Test::Helper::ExchangeRates                    qw/populate_exchange_rates/;
use LandingCompany::Registry;
use Date::Utility;

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my %rates = map { $_ => 100 } LandingCompany::Registry::all_currencies();
populate_exchange_rates(\%rates);

my $dashboard = BOM::RiskReporting::Dashboard->new(
    start => Date::Utility->new('2005-09-21 06:46:00'),
    end   => Date::Utility->new('2017-11-14 12:00:00'));

my $report = $dashboard->_payment_and_profit_report;
is_deeply([sort keys %$report], ['big_deposits', 'big_losers', 'big_winners', 'big_withdrawals', 'watched'], "keys correct");
is(scalar(@{$report->{big_deposits}}), '10', 'big_deposits number correct');

my @crypto_pairs = LandingCompany::Registry::all_currencies();

subtest 'All pairs' => sub {
    my $amount;
    for (@crypto_pairs) {
        $amount = $dashboard->amount_in_usd(100, $_);
        isnt($amount, 0, 'Found usd rates for ' . $_);
    }
};

subtest 'no such coin' => sub {
    my $currency = 'NO_SUCH_COIN';
    my $amount   = $dashboard->amount_in_usd(100, $currency);
    is($amount, 0, $currency . ' is not a valid currency');
};

done_testing;
