use strict;
use warnings;

use Data::Dumper;
use JSON;
use Test::Most;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use Test::MockModule;
use BOM::Database::Model::AccessToken;

my $t = build_wsapi_test({
        debug    => 1,
        language => 'RU'
    },
    {Origin => 'http://test.com'},
);
my ($req_storage, $res, $start, $end);

my $datadog = Test::MockModule->new('DataDog::DogStatsd::Helper');
my $timing  = [];
my $stats   = [];
$datadog->mock('stats_timing', sub { push @$timing, \@_ });
$datadog->mock('stats_inc',    sub { push @$stats,  \@_ });

$t->send_ok({json => {website_status => 1}})->message_ok;
$res = decode_json($t->message->[1]);

is @$timing, 2, 'Should make 2 logs';

is $timing->[0]->[0], 'bom_websocket_api.v_3.rpc.call.timing';
ok $timing->[0]->[1], 'Should log timing';
is $timing->[0]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

is $timing->[1]->[0], 'bom_websocket_api.v_3.rpc.call.timing.sent';
ok $timing->[1]->[1], 'Should log timing';
is $timing->[1]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

is $stats->[0]->[0], 'bom_websocket_api.v_3.call.website_status';
is $stats->[0]->[1]->{tags}->[0], 'origin:test.com', 'Should set req origin';

@$timing = ();
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

is @$timing, 3, 'Should make 3 logs';

is $timing->[1]->[0], 'bom_websocket_api.v_3.rpc.call.timing.connection';
ok $timing->[1]->[1], 'Should log timing';
is $timing->[1]->[2]->{tags}->[0], 'rpc:send_ask', 'Should set tag with rpc method name';

my $token = BOM::Database::Model::AccessToken->new->create_token("CR0021", 'Test', ['trade']);
$t       = $t->send_ok({json => {authorize => $token}})->message_ok;
$res     = decode_json($t->message->[1]);
@$timing = ();
$t       = $t->send_ok({
        json => {
            buy   => 1,
            price => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'InvalidContractProposal', 'Should save only timing sent log, if dont call RPC';

is $timing->[0]->[0], 'bom_websocket_api.v_3.rpc.call.timing.sent';
ok $timing->[0]->[1], 'Should log timing';
is $timing->[0]->[2]->{tags}->[0], 'rpc:buy', 'Should set tag with rpc method name';

@$timing = ();
my ($fake_rpc_response, $fake_rpc_client, $rpc_client_mock);
$fake_rpc_response = Test::MockObject->new();
$fake_rpc_response->mock('is_error',      sub { 1 });
$fake_rpc_response->mock('result',        sub { +{} });
$fake_rpc_response->mock('error_message', sub { 'error' });
$fake_rpc_client = Test::MockObject->new();
$fake_rpc_client->mock('call', sub { shift; return $_[2]->($fake_rpc_response) });
$rpc_client_mock = Test::MockModule->new('MojoX::JSON::RPC::Client');
$rpc_client_mock->mock('new', sub { return $fake_rpc_client });

my $warn_string;
{
    local $SIG{'__WARN__'} = sub { $warn_string = shift; };
    $t->send_ok({json => {website_status => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
}
like $warn_string, qr/error/, 'Should make warning if RPC response is_error method is true';

is $res->{error}->{code}, 'CallError', 'Should make timing if returns CallError';

is $timing->[0]->[0], 'bom_websocket_api.v_3.rpc.call.timing';
ok $timing->[0]->[1], 'Should log timing';
is $timing->[0]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

is $timing->[1]->[0], 'bom_websocket_api.v_3.rpc.call.timing.sent';
ok $timing->[1]->[1], 'Should log timing';
is $timing->[1]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

@$timing = ();
$fake_rpc_client->mock('call', sub { shift; return $_[2]->('') });

{
    local $SIG{'__WARN__'} = sub { $warn_string = shift; };
    $t->send_ok({json => {website_status => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
}
like $warn_string, qr/WrongResponse/, 'Should make warning if RPC response is empty';

is $res->{error}->{code}, 'WrongResponse', 'Should make timing if returns WrongResponse';

is $timing->[0]->[0], 'bom_websocket_api.v_3.rpc.call.timing';
ok $timing->[0]->[1], 'Should log timing';
is $timing->[0]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

is $timing->[1]->[0], 'bom_websocket_api.v_3.rpc.call.timing.sent';
ok $timing->[1]->[1], 'Should log timing';
is $timing->[1]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

$t->finish_ok;

done_testing();
