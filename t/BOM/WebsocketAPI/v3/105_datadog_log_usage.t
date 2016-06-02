use strict;
use warnings;

use Data::Dumper;
use JSON;
use Test::Most;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use Test::MockModule;

my $t = build_mojo_test({
    debug    => 1,
    language => 'RU'
});
my ($req_storage, $res, $start, $end);

my $datadog = Test::MockModule->new('DataDog::DogStatsd::Helper');
my $params  = [];
$datadog->mock('stats_timing', sub { push @$params, \@_ });

$t->send_ok({json => {website_status => 1}})->message_ok;
$res = decode_json($t->message->[1]);

is @$params, 2, 'Should make 2 logs';

is $params->[0]->[0], 'bom_websocket_api.v_3.rpc.call.timing';
ok $params->[0]->[1], 'Should log timing';
is $params->[0]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

is $params->[1]->[0], 'bom_websocket_api.v_3.rpc.call.timing.sent';
ok $params->[1]->[1], 'Should log timing';
is $params->[1]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

@$params = ();
my %contractParameters = (
    "amount"        => "5",
    "basis"         => "payout",
    "contract_type" => "CALL",
    "currency"      => "USD",
    "symbol"        => "R_50",
    "duration"      => "2",
    "duration_unit" => "m",
);
$t = $t->send_ok({
        json => {
            "proposal"  => 1,
            "subscribe" => 1,
            %contractParameters
        }})->message_ok;

$res = decode_json($t->message->[1]);

is @$params, 3, 'Should make 3 logs';

is $params->[1]->[0], 'bom_websocket_api.v_3.rpc.call.timing.connection';
ok $params->[1]->[1], 'Should log timing';
is $params->[1]->[2]->{tags}->[0], 'rpc:send_ask', 'Should set tag with rpc method name';

my $token = BOM::Platform::SessionCookie->new(
    loginid => "CR0021",
    email   => 'shuwnyuan@regentmarkets.com',
)->token;
$t = $t->send_ok({json => {authorize => $token}})->message_ok;
$res = decode_json($t->message->[1]);
@$params = ();
$t = $t->send_ok({
        json => {
            buy   => 1,
            price => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'InvalidContractProposal', 'Should save only timing sent log, if dont call RPC';

is $params->[0]->[0], 'bom_websocket_api.v_3.rpc.call.timing.sent';
ok $params->[0]->[1], 'Should log timing';
is $params->[0]->[2]->{tags}->[0], 'rpc:buy', 'Should set tag with rpc method name';

@$params = ();
my ($fake_rpc_response, $fake_rpc_client, $rpc_client_mock);
$fake_rpc_response = Test::MockObject->new();
$fake_rpc_response->mock('is_error', sub { 1 });
$fake_rpc_response->mock('error_message', sub { 'error' });
$fake_rpc_client = Test::MockObject->new();
$fake_rpc_client->mock('call', sub { shift; return $_[2]->($fake_rpc_response) });
$rpc_client_mock = Test::MockModule->new('MojoX::JSON::RPC::Client');
$rpc_client_mock->mock('new', sub { return $fake_rpc_client });

$t->send_ok({json => {website_status => 1}})->message_ok;
$res = decode_json($t->message->[1]);

is $res->{error}->{code}, 'CallError', 'Should make timing if returns CallError';

is $params->[0]->[0], 'bom_websocket_api.v_3.rpc.call.timing';
ok $params->[0]->[1], 'Should log timing';
is $params->[0]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

is $params->[1]->[0], 'bom_websocket_api.v_3.rpc.call.timing.sent';
ok $params->[1]->[1], 'Should log timing';
is $params->[1]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

@$params = ();
$fake_rpc_client->mock('call', sub { shift; return $_[2]->('') });

$t->send_ok({json => {website_status => 1}})->message_ok;
$res = decode_json($t->message->[1]);

is $res->{error}->{code}, 'WrongResponse', 'Should make timing if returns WrongResponse';

is $params->[0]->[0], 'bom_websocket_api.v_3.rpc.call.timing';
ok $params->[0]->[1], 'Should log timing';
is $params->[0]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

is $params->[1]->[0], 'bom_websocket_api.v_3.rpc.call.timing.sent';
ok $params->[1]->[1], 'Should log timing';
is $params->[1]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

$t->finish_ok;

done_testing();
