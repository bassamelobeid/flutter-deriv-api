use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::Database::Model::AccessToken;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use await;

my $t = build_wsapi_test();

my $token = BOM::Database::Model::AccessToken->new->create_token('CR2002', 'Test Token', ['read']);

my $authorize = $t->await::authorize({ authorize => $token });
is $authorize->{authorize}->{email},   'sy@regentmarkets.com';
is $authorize->{authorize}->{loginid}, 'CR2002';
test_schema('authorize', $authorize);

## it's ok after authorize
my $balance = $t->await::balance({ balance => 1 });
ok($balance->{balance});
test_schema('balance', $balance);

$t->finish_ok;

done_testing();
