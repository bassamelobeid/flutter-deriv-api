use strict;
use warnings;

use Test::More (tests => 4);
use Test::Exception;
use Test::Warnings;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use Date::Utility;
use BOM::Database::DataMapper::Payment::FreeGift;

my $payment_data_mapper;

lives_ok {
    $payment_data_mapper = BOM::Database::DataMapper::Payment::FreeGift->new({
        broker_code => 'CR',
    });
}
'Expect to initialize the object';

my $now            = Date::Utility->new;
my $date_31_Aug_09 = Date::Utility->new("31-Aug-09")->truncate_to_day;
my $accounts       = $payment_data_mapper->get_clients_with_only_one_freegift_transaction_and_inactive($date_31_Aug_09);

is(scalar @$accounts, 1, 'check number of client that dont use free gift before_than 31_Aug_09');

cmp_ok($accounts->[0]->{client_loginid}, 'eq', "CR0006", "CR0006 hasnt used his freegift");
