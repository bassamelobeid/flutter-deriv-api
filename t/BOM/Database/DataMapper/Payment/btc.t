use strict;
use warnings;

use Test::More (tests => 3);
use Test::Exception;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use Date::Utility;
use BOM::Database::DataMapper::Payment::Btc;

my $payment_data_mapper;

lives_ok {
    $payment_data_mapper = BOM::Database::DataMapper::Payment::Btc->new({
        broker_code => 'CR',
    });
}
'Expect to initialize the object';

my $dupe = $payment_data_mapper->is_duplicate_payment({transaction_id => 'MY_LEAST_FAVORITE_BITCOIN'});

is($dupe, undef, 'we should not have a duplicate payment yet');

my $dupe = $payment_data_mapper->is_duplicate_payment({transaction_id => 'MY_FAVORITE_BITCOIN'});

is($dupe, 1, 'we have a duplicate');
