use strict;
use warnings;
use Test::More;

use BOM::Database::DataMapper::CollectorReporting;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use Date::Utility;

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my $report_mapper = BOM::Database::DataMapper::CollectorReporting->new({db => $test_client->db});
my @payments = $report_mapper->get_active_accounts_payment_profit({
        start_time => Date::Utility->new('2005-09-21 06:46:00'),
        end_time   => Date::Utility->new('2017-11-14 12:00:00')});
@payments = sort { $a->{account_id} <=> $b->{account_id} } @payments;

my ($repetitions) = $test_client->db->dbic->run(
    fixup => sub {
        $_->selectrow_array("select count(*) from betonmarkets.production_servers where real_money = 't'");
    });

is(scalar @payments, 34 * $repetitions, "number of rows is correct");
is_deeply(
    [sort keys %{$payments[0]}],
    [
        'account_id', 'affiliate_email', 'affiliate_username', 'affiliation',  'currency', 'loginid',
        'name',       'payments',        'profit',             'usd_payments', 'usd_profit'
    ],
    "key is correct"
);
done_testing;
