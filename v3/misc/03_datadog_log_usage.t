use strict;
use warnings;

use Test::Most;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use Test::MockModule;
use Test::MockObject;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::User;
use List::Util qw/first/;

use await;

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

$res = $t->await::website_status({website_status => 1});

is @$timing, 3, 'Should make 3 logs';

is $timing->[0]->[0], 'bom_websocket_api.v_3.rpc.call.timing';
ok $timing->[0]->[1], 'Should log timing';
cmp_bag $timing->[0]->[2]->{tags}, ['brand:binary', 'rpc:website_status', 'stream:general'], 'Metric tags are correct';

is $timing->[1]->[0], 'bom_websocket_api.v_3.rpc.call.timing.response.latency';
ok $timing->[1]->[1], 'Should log response latency timing';
cmp_bag $timing->[0]->[2]->{tags}, ['brand:binary', 'rpc:website_status', 'stream:general'], 'Metric tags are correct';

is $timing->[2]->[0], 'bom_websocket_api.v_3.rpc.call.timing.sent';
ok $timing->[2]->[1], 'Should log timing';
is $timing->[2]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

is $stats->[0]->[0], 'bom_websocket_api.unknown_ip.count';
my $call_stat = first { $_->[0] eq 'bom_websocket_api.v_3.call.all' } @$stats;
is $call_stat->[1]->{tags}->[0], 'origin:test.com', 'Should set req origin';

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
$res = $t->await::proposal({
    "proposal"  => 1,
    "subscribe" => 1,
    %contractParameters
});

is @$timing, 4, 'Should make 4 logs. Added pre_rpc log';

is $timing->[1]->[0], 'bom_websocket_api.v_3.rpc.call.timing.connection';
ok $timing->[1]->[1], 'Should log timing';
is $timing->[1]->[2]->{tags}->[0], 'rpc:send_ask', 'Should set tag with rpc method name';

is $timing->[2]->[0], 'bom_websocket_api.v_3.rpc.call.timing.response.latency';
ok $timing->[2]->[1], 'Should log timing';

my $email  = 'test-binary' . rand(999) . '@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->save;
$client->set_default_account('USD');

my $loginid = $client->loginid;
my $user    = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($client);

my $token = BOM::Platform::Token::API->new->create_token($loginid, 'Test', ['trade']);
$t->await::authorize({authorize => $token});
@$timing = ();
$res     = $t->await::buy({
    buy   => 1,
    price => 1,
});
is $res->{error}->{code}, 'InvalidContractProposal', 'Should save only timing sent log, if dont call RPC';

is $timing->[0]->[0], 'bom_websocket_api.v_3.rpc.call.timing.sent';
ok $timing->[0]->[1], 'Should log timing';
is $timing->[0]->[2]->{tags}->[0], 'rpc:buy', 'Should set tag with rpc method name';

@$timing = ();

my ($fake_rpc_response, $rpc_client_mock);

$fake_rpc_response = Test::MockObject->new();
$fake_rpc_response->mock('is_error',      sub { 1 });
$fake_rpc_response->mock('result',        sub { +{} });
$fake_rpc_response->mock('error_message', sub { 'dummy' });
$fake_rpc_response->mock('error_code',    sub { 'dummy' });

# Json RPC compatible
$rpc_client_mock = Test::MockModule->new('MojoX::JSON::RPC::Client');
$rpc_client_mock->mock('call', sub { shift; return $_[2]->($fake_rpc_response) });

# RPC Queue compatible
{
    no warnings qw(redefine);    ## no critic (ProhibitNoWarnings)

    *MojoX::JSON::RPC::Client::ReturnObject::new = sub {
        return $fake_rpc_response;
    }
}

{
    $res = $t->await::website_status({website_status => 1});
}
is $res->{error}->{code}, 'CallError', 'Should make timing if returns CallError';

is $timing->[0]->[0], 'bom_websocket_api.v_3.rpc.call.timing';
ok $timing->[0]->[1], 'Should log timing';
cmp_bag $timing->[0]->[2]->{tags}, ['brand:binary', 'rpc:website_status', 'source_type:official', 'stream:general'], 'Metric tags are correct';

is $timing->[1]->[0], 'bom_websocket_api.v_3.rpc.call.timing.sent';
ok $timing->[1]->[1], 'Should log timing';
is $timing->[1]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

@$timing = ();

# Json RPC compatible
my $fake_req = Test::MockObject->new();
my $fake_tx  = Test::MockObject->new();
$fake_req->mock('url', sub { return "fake req url" });
$fake_tx->mock('error', sub { return +{} });
$fake_tx->mock('req',   sub { return $fake_req });
$rpc_client_mock->mock('tx',   sub { return $fake_tx });
$rpc_client_mock->mock('call', sub { shift; return $_[2]->('') });

# RPC Queue compatible
{
    no warnings qw(redefine);    ## no critic (ProhibitNoWarnings)

    *MojoX::JSON::RPC::Client::ReturnObject::new = sub {
        return '';
    }
}

{
    local $SIG{'__WARN__'} = sub { };
    $res = $t->await::website_status({website_status => 1});
}

is $res->{error}->{code}, 'WrongResponse', 'Should make timing if returns WrongResponse';

is $timing->[0]->[0], 'bom_websocket_api.v_3.rpc.call.timing';
ok $timing->[0]->[1], 'Should log timing';
cmp_bag $timing->[0]->[2]->{tags}, ['brand:binary', 'rpc:website_status', 'source_type:official', 'stream:general'], 'Metric tags are correct';

is $timing->[1]->[0], 'bom_websocket_api.v_3.rpc.call.timing.sent';
ok $timing->[1]->[1], 'Should log timing';
is $timing->[1]->[2]->{tags}->[0], 'rpc:website_status', 'Should set tag with rpc method name';

$t->finish_ok;

done_testing();
