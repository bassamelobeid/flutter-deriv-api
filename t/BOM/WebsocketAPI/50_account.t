use strict;
use warnings;
use Test::More;
use Test::Mojo;
use FindBin qw/$Bin/;
use JSON::Schema;
use File::Slurp;
use JSON;
use Data::Dumper;
use Date::Utility;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $config_dir = "$Bin/../../../config/v1";

my $t = Test::Mojo->new('BOM::WebSocketAPI');
$t->websocket_ok("/websockets/contracts");

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

## validate statement
# my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$config_dir/statement/receive.json")));
# my $result    = $validator->validate($statement);
# ok $result, "statement response is valid";
# diag " - $_\n" foreach $result->errors;

$t = $t->send_ok({json => {statement => {limit => 2}}})->message_ok;
$statement = decode_json($t->message->[1]);
ok($statement->{statement});
is($statement->{statement}->{count}, 2);

$t->finish_ok;

done_testing();
