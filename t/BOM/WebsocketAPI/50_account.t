use strict;
use warnings;
use Test::More;
use Test::Mojo;
use JSON;
use Data::Dumper;
use Date::Utility;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $t = Test::Mojo->new('BOM::WebSocketAPI');
$t->websocket_ok("/websockets/contracts");

my $token = BOM::Platform::SessionCookie->new(
    loginid         => "CR0021",
    email           => 'cr0021@binary.com',
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'cr0021@binary.com';
is $authorize->{authorize}->{loginid}, 'CR0021';

$t = $t->send_ok({json => {statement => { limit => 100 }}})->message_ok;
my $statement = decode_json($t->message->[1]);
ok($statement->{statement});
is($statement->{statement}->{count}, 100);

$t = $t->send_ok({json => {statement => { limit => 2 }}})->message_ok;
my $statement = decode_json($t->message->[1]);
diag Dumper(\$statement);
ok($statement->{statement});
is($statement->{statement}->{count}, 2);

$t->finish_ok;

done_testing();
