use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $t = build_mojo_test();

my $token = BOM::Platform::SessionCookie->new(
    loginid => "CR0021",
    email   => 'cr0021@binary.com',
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'cr0021@binary.com';
is $authorize->{authorize}->{loginid}, 'CR0021';

$t = $t->send_ok({json => {statement => {limit => 100}}})->message_ok;
my $statement = decode_json($t->message->[1]);
ok($statement->{statement});
is($statement->{statement}->{count}, 100);
test_schema('statement', $statement);

$t = $t->send_ok({json => {statement => {limit => 2}}})->message_ok;
$statement = decode_json($t->message->[1]);
ok($statement->{statement});
is($statement->{statement}->{count}, 2);
test_schema('statement', $statement);

## balance
$t = $t->send_ok({json => {balance => 1}})->message_ok;
my $balance = decode_json($t->message->[1]);
ok($balance->{balance});
test_schema('balance', $balance);
# diag Dumper(\$balance);

$t->finish_ok;

done_testing();
