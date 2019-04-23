use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Format::Util::Numbers qw/financialrounding/;

use BOM::MyAffiliates::TurnoverReporter;
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::DataMapper::FinancialMarketBet;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code        => 'CR',
    myaffiliates_token => 'dummy_affiliate_token',
});
my $account = $client->set_default_account('USD');

$client->payment_free_gift(
    currency => 'USD',
    amount   => 1000,
    remark   => 'free gift',
);

my $date       = Date::Utility->new('2017-09-01 00:01:01');
my $start_date = $date->plus_time_interval('1h')->datetime;
my $end_date   = $date->plus_time_interval('6h')->datetime;

BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
    type             => 'fmb_higher_lower_sold_won',
    account_id       => $account->id,
    purchase_time    => $start_date,
    transaction_time => $start_date,
    start_time       => $start_date,
    expiry_time      => $end_date,
    settlement_time  => $end_date,
});

my $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
    client_loginid => $account->client_loginid,
    currency_code  => $account->currency_code
});

my $reporter = BOM::MyAffiliates::TurnoverReporter->new;

my @csv = BOM::MyAffiliates::TurnoverReporter->new->activity_for_date_as_csv('2017-09-01');

ok scalar @csv, 'got some records';

my @row = split ',', $csv[0];
is $row[0], '2017-09-01', 'got correct transaction time';
is $row[1], $client->loginid, 'got correct loginid';

ok $row[2], 'has stake price';
ok $row[3], 'has payout price';
cmp_ok($row[4], '==', financialrounding('price', 'USD', ($row[2] / $row[3] * 100)), 'got proper probability');
ok $row[5], 'has reference id';

done_testing();
