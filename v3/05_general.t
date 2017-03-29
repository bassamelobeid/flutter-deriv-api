use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use Test::MockObject;
use Test::MockModule;

my $system = Test::MockModule->new('Binary::WebSocketAPI::v3::Wrapper::System');
$system->mock('server_time', sub { +{msg_type => 'time', time => ('1' x 600000)} });

my $t = build_wsapi_test();

$t = $t->send_ok({json => 'notjson'})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{msg_type}, 'error';
is $res->{error}->{code}, 'BadRequest';
ok ref($res->{echo_req}) eq 'HASH' && !keys %{$res->{echo_req}};

$t = $t->send_ok({json => {UnrecognisedRequest => 1}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{msg_type}, 'error';
is $res->{error}->{code}, 'UnrecognisedRequest';

$t = $t->send_ok({json => {ping => 1}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{msg_type}, 'ping';
is $res->{ping},     'pong';
test_schema('ping', $res);

$t = $t->send_ok({json => {time => 1}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'ResponseTooLarge', 'API response without RPC forwarding should be checked to size';

my ($fake_rpc_response, $fake_rpc_client, $rpc_client_mock);
$fake_rpc_response = Test::MockObject->new();
$fake_rpc_response->mock('is_error', sub { '' });
$fake_rpc_response->mock('result', sub { +{ok => ('1' x 600000)} });
$fake_rpc_client = Test::MockObject->new();
$fake_rpc_client->mock('call', sub { shift; return $_[2]->($fake_rpc_response) });
$rpc_client_mock = Test::MockModule->new('MojoX::JSON::RPC::Client');
$rpc_client_mock->mock('new', sub { return $fake_rpc_client });

$t = $t->send_ok({
        json => {
            website_status => 1,
            req_id         => 3
        }})->message_ok;
$res = decode_json($t->message->[1]);
### Now it forwared
### is $res->{error}->{code},              'ResponseTooLarge';
is $res->{echo_req}->{website_status}, 1;
is $res->{req_id}, 3;

$rpc_client_mock->unmock_all;

$t->finish_ok;

done_testing();
