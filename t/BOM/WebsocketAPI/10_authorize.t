use strict;
use warnings;
use Test::More;
use Test::Mojo;
use FindBin qw/$Bin/;
use JSON::Schema;
use File::Slurp;
use JSON;
use Data::Dumper;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $config_dir = "$Bin/../../../config/v1";

my $t = Test::Mojo->new('BOM::WebSocketAPI');
$t->websocket_ok("/websockets/contracts");

my $faked_token = 'ABC';
$t = $t->send_ok({json => {authorize => $faked_token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{error}->{code}, 'InvalidToken';

my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$config_dir/authorize/receive.json")));
my $result    = $validator->validate(decode_json $t->message->[1]);
ok $result, "authorize response is valid";
# diag " - $_\n" foreach $result->errors;

my $token = BOM::Platform::SessionCookie->new(
    client_id       => 1,
    loginid         => "CR2002",
    email           => 'CR2002@binary.com',
    expiration_time => time() + 600,
    scopes          => ['price', 'trade'],
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
$authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'CR2002@binary.com';
is $authorize->{authorize}->{loginid}, 'CR2002';

$validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$config_dir/authorize/receive.json")));
$result    = $validator->validate(decode_json $t->message->[1]);
ok $result, "authorize response is valid";
# diag " - $_\n" foreach $result->errors;

$t->finish_ok;

done_testing();
