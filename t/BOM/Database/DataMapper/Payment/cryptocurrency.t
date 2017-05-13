use strict;
use warnings;

use Test::More (tests => 3);
use Test::Exception;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use Date::Utility;
use BOM::Database::DataMapper::Payment::CryptoCurrency;

my $payment_data_mapper;

lives_ok {
    $payment_data_mapper = BOM::Database::DataMapper::Payment::CryptoCurrency->new({
        broker_code     => 'CR',
        currency_code   => 'XBT'
    });
}
'Expect to initialize the object';

my $dupe = $payment_data_mapper->is_duplicate_payment({address => 'MY_LEAST_FAVORITE_BITCOIN'});

is($dupe, undef, 'we should not have a duplicate payment yet');

$dupe = $payment_data_mapper->is_duplicate_payment({address => 'SOMEBODY_ELSES_COIN', client_loginid => 'MT1500'});

is($dupe, 1, 'we have a duplicate');
