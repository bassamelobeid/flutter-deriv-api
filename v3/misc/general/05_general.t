use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test reconnect/;
use Test::MockObject;
use Test::MockModule;

use await;

my $system = Test::MockModule->new('Binary::WebSocketAPI::v3::Wrapper::System');
$system->mock('server_time', sub { +{msg_type => 'time', time => ('1' x 600000)} });

my $t = build_wsapi_test();

{
    # malformed inputs now close the WebSocket connection
    my $res = $t->send_ok({json => 'notjson'})->finished_ok(1007);
    reconnect($t);
}

{
    my $res = $t->await::error({
        UnrecognisedRequest => 1,
        req_id              => 1
    });
    is $res->{error}->{code}, 'UnrecognisedRequest';
    is $res->{req_id}, 1, 'Response contains matching req_id';
}

{
    my $res = $t->await::ping({
        ping   => 1,
        req_id => 2
    });
    is $res->{msg_type}, 'ping';
    is $res->{ping},     'pong';
    is $res->{req_id},   2, 'Response contains matching req_id';
    test_schema('ping', $res);
}

{
    my $res = $t->await::time({time => 1});

    is $res->{error}->{code}, 'ResponseTooLarge', 'API response without RPC forwarding should be checked to size';
}

{
    my ($fake_rpc_response, $fake_rpc_client, $rpc_client_mock);
    $fake_rpc_response = Test::MockObject->new();
    $fake_rpc_response->mock('is_error', sub { '' });
    $fake_rpc_response->mock('result', sub { +{ok => ('1' x 600000)} });
    $fake_rpc_client = Test::MockObject->new();
    $fake_rpc_client->mock('call', sub { shift; return $_[2]->($fake_rpc_response) });
    $rpc_client_mock = Test::MockModule->new('MojoX::JSON::RPC::Client');
    $rpc_client_mock->mock('new', sub { return $fake_rpc_client });

    my $res = $t->await::website_status({
        website_status => 1,
        req_id         => 3
    });

    is $res->{echo_req}->{website_status}, 1;
    is $res->{req_id}, 3;

    $rpc_client_mock->unmock_all;
}

{
    # Some Unicode character that will fail sanity check
    my $res = $t->await::sanity_check({
        ping   => "\x{0BF0}",
        req_id => 4
    });
    is $res->{error}->{code}, 'SanityCheckFailed';
    is $res->{req_id}, 4, 'Response contains matching req_id';
}

{
    my $res = $t->await::ping({
        ping   => 1,
        req_id => 0
    });
    is $res->{req_id}, 0, 'Zero req_id is returned';
}

{
    my $res = $t->await::ping({
        ping   => "xyz",
        req_id => 123
    });
    is $res->{error}->{code}, 'InputValidationFailed', 'Schema validation failed';
    is $res->{req_id}, 123, 'Response contains matching req_id';
}

$t->finish_ok;

done_testing();
