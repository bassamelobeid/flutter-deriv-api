
use Test::Most;
use Test::Mojo;

my $svr = $ENV{BOM_WEBSOCKETS_SVR} || '';
my $t   = $svr? Test::Mojo->new: Test::Mojo->new('BOM::WebSocketAPI');

$t->websocket_ok("$svr/websockets/contracts");

$t->send_ok('some random stuff not even json', 'sent random stuff not even json, will be ignored');
$t->send_ok({json=>{this=>'that'}},            'valid json but nonsense message, will be ignored');

my ($test_name, $response);

sub same_structure_tests {
    my ($msg_type, $request) = @_;
    explain "$test_name request is ", $request;
    $t->send_ok({json=>$request}, "send request for $test_name");
    $t->message_ok("$test_name got a response");
    $response = Mojo::JSON::decode_json $t->message->[1];
    explain "$test_name response was ", $response;
    $t->json_message_has('/echo_req', "$test_name request echoed");
    $t->json_message_is('/msg_type', $msg_type, "$test_name msg_type is $msg_type");
}

#____________________________________________________________________
$test_name = 'bad auth attempt';

&same_structure_tests('authorize', {authorize=>'xyz'});
$t->json_message_is('/authorize/error/code' => 'InvalidToken', "$test_name rejected properly");

#____________________________________________________________________
$test_name = 'tick stream test';

&same_structure_tests('tick', {ticks=>'R_50'});
my $tick_id = $response->{tick} && $response->{tick}{id};
for (my $i=1; $i <= 3; $i++) {
    $t->json_message_has('/tick/epoch', "$test_name $i epoch present");
    $t->json_message_has('/tick/quote', "$test_name $i quote present");
    $t->json_message_has('/tick/id', "$test_name $i id present");
    $t->message_ok("$test_name got followup response number $i");
}
$t->send_ok({json=>{forget=>$tick_id}}, "$test_name over, cancelled id $tick_id");

#____________________________________________________________________
$test_name = 'historical ticks test';

&same_structure_tests('history', {ticks=>'R_50', end=>'latest'});
$t->json_message_has('/history/prices', "$test_name prices present");
$t->json_message_has('/history/times', "$test_name times present");

#____________________________________________________________________
$test_name = 'candles test';

&same_structure_tests('candles', {ticks=>'R_50', end=>'latest', granularity=>'H7'});
$t->json_message_has('/candles', "$test_name candles present");
isa_ok($response->{candles}, 'ARRAY', 'candles slot');

#____________________________________________________________________
$test_name = 'candles test with bad granularity';

&same_structure_tests('candles', {ticks=>'R_50', end=>'latest', granularity=>'xxH7'});
$t->json_message_is('/error', 'invalid candles request', 'bad granularity string rejected');

#____________________________________________________________________
done_testing();
