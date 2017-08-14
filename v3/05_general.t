use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use Test::MockObject;
use Test::MockModule;

use await;

my $system = Test::MockModule->new('Binary::WebSocketAPI::v3::Wrapper::System');
$system->mock('server_time', sub { +{msg_type => 'time', time => ('1' x 600000)} });

my $t = build_wsapi_test();

my $res = $t->await::error('notjson');
is $res->{error}->{code}, 'BadRequest';
ok ref($res->{echo_req}) eq 'HASH' && !keys %{$res->{echo_req}};

$res = $t->await::error({UnrecognisedRequest => 1});
is $res->{error}->{code}, 'UnrecognisedRequest';

$res = $t->await::ping({ping => 1});
is $res->{msg_type}, 'ping';
is $res->{ping},     'pong';
test_schema('ping', $res);

$res = $t->await::time({time => 1});

is $res->{error}->{code}, 'ResponseTooLarge', 'API response without RPC forwarding should be checked to size';

my ($fake_rpc_response, $fake_rpc_client, $rpc_client_mock);
$fake_rpc_response = Test::MockObject->new();
$fake_rpc_response->mock('is_error', sub { '' });
$fake_rpc_response->mock('result', sub { +{ok => ('1' x 600000)} });
$fake_rpc_client = Test::MockObject->new();
$fake_rpc_client->mock('call', sub { shift; return $_[2]->($fake_rpc_response) });
$rpc_client_mock = Test::MockModule->new('MojoX::JSON::RPC::Client');
$rpc_client_mock->mock('new', sub { return $fake_rpc_client });

$res = $t->await::website_status({
    website_status => 1,
    req_id         => 3
});

is $res->{echo_req}->{website_status}, 1;
is $res->{req_id}, 3;

$rpc_client_mock->unmock_all;

$t->finish_ok;

done_testing();
