use strict;
use warnings;
use Test::More;

use BOM::Database::DataMapper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $res;
my $details = {
	first_name => 'Bond', # Adding space to check
	last_name => 'Lim',
	date_of_birth => '1932-09-07',
};

$res = BOM::Database::DataMapper::Client->new({broker_code => 'CR'})->get_duplicate_client($details);
cmp_ok($res, '>', 1, 'It finds duplicats');

$details->{first_name} = $details->{first_name} . ' ';
$res = BOM::Database::DataMapper::Client->new({broker_code => 'CR'})->get_duplicate_client($details);
cmp_ok($res, '>', 1, 'It finds duplicats even with extra space');

$details->{first_name} = 'NAME NOT THERE';
$res = BOM::Database::DataMapper::Client->new({broker_code => 'CR'})->get_duplicate_client($details);
cmp_ok($res, '==', 0, 'But it does not exists, it will return 0');

done_testing();