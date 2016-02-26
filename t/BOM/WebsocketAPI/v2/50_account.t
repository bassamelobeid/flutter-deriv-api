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
use BOM::Test::Data::Utility::UnitTestMD qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $t = build_mojo_test();

my $token = BOM::Platform::SessionCookie->new(
    loginid => "CR0021",
    email   => 'shuwnyuan@regentmarkets.com',
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'shuwnyuan@regentmarkets.com';
is $authorize->{authorize}->{loginid}, 'CR0021';

$t = $t->send_ok({
        json => {
            statement => 1,
            limit     => 54
        }})->message_ok;
my $statement = decode_json($t->message->[1]);
ok($statement->{statement});
is($statement->{statement}->{count}, 54);
test_schema('statement', $statement);

## balance
$t = $t->send_ok({json => {balance => 1}})->message_ok;
my $balance = decode_json($t->message->[1]);
ok($balance->{balance});
test_schema('balance', $balance);
# diag Dumper(\$balance);

$t = $t->send_ok({
        json => {
            profit_table => 1,
            limit        => 1,
        }})->message_ok;
my $profit_table = decode_json($t->message->[1]);
ok($profit_table->{profit_table});
ok($profit_table->{profit_table}->{count});
my $trx = $profit_table->{profit_table}->{transactions}->[0];
ok($trx);
ok($trx->{$_}, "got $_") foreach (qw/sell_price buy_price purchase_time contract_id transaction_id/);
test_schema('profit_table', $profit_table);

$t->finish_ok;

done_testing();
