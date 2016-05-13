use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use Test::MockModule;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $t = build_mojo_test();

# check for authenticated call
$t = $t->send_ok({json => {sell_expired => 1}})->message_ok;
my $response = decode_json($t->message->[1]);

is $response->{msg_type}, 'sell_expired';
is $response->{error}->{code},    'AuthorizationRequired';
is $response->{error}->{message}, 'Please log in.';

my $token = BOM::Platform::SessionCookie->new(
    loginid => "CR0021",
    email   => 'shuwnyuan@regentmarkets.com',
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'shuwnyuan@regentmarkets.com';
is $authorize->{authorize}->{loginid}, 'CR0021';

# wrong call
$t = $t->send_ok({json => {sell_expired => 2}})->message_ok;
$response = decode_json($t->message->[1]);

is $response->{error}->{code}, 'InputValidationFailed';

my $rpc_caller = Test::MockModule->new('BOM::WebSocketAPI::CallingEngine');
my $call_params;
$rpc_caller->mock('call_rpc', sub { $call_params = $_[1]->{call_params}, shift->send({json => {ok => 1}}) });
$t = $t->send_ok({json => {sell_expired => 1}})->message_ok;
ok $call_params->{source};
is $call_params->{token}, $token;
$rpc_caller->unmock_all;

$t = $t->send_ok({
        json => {
            sell_expired => 1,
            req_id       => 'test'
        }})->message_ok;
$response = decode_json($t->message->[1]);

is $response->{msg_type}, 'sell_expired';
is $response->{echo_req}->{sell_expired}, 1;
is $response->{echo_req}->{req_id},       'test';
is $response->{req_id}, 'test';

done_testing();
