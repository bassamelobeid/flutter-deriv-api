use Test::Most;
use Test::Mojo;
use JSON::Schema;
use JSON;
use File::Slurp;

my $svr = $ENV{BOM_WEBSOCKETS_SVR} || '';
my $t   = $svr? Test::Mojo->new: Test::Mojo->new('BOM::WebSocketAPI');

$t->websocket_ok("$svr/websockets/contracts");

$t->send_ok('some random stuff not even json', 'sent random stuff not even json, will be ignored');
$t->send_ok({json=>{this=>'that'}},            'valid json but nonsense message, will be ignored');

my ($test_name, $response);

opendir(my $dh, './config/v1') || die;
my @f = ();
while(my $f = readdir $dh) {
    next if ($f eq '.' or $f eq '..');
    push @f, $f;
}

sub strip_doc_send {
    my $data = shift;
    my $r;
    for my $p (keys %{$data->{properties}}) {
        $r->{$p} = $data->{properties}->{$p}->{default};
    }
    return $r;
}

foreach my $f (@f) {
    $test_name = $f;
    next if (!$ENV{TRAVIS} and $f eq 'tick');
    my $send = strip_doc_send(JSON::from_json(File::Slurp::read_file("config/v1/$f/send.json")));
    my $response_json = &same_structure_tests($f, $send);
    my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("config/v1/$f/receive.json")));
    my $result    = $validator->validate($response_json);
    ok $result, "$f response is valid"; # print " - $_\n" foreach $result->errors;
}

sub same_structure_tests {
    my ($msg_type, $request) = @_;
    $t->send_ok({json=>$request}, "send request for $test_name");
    $t->message_ok("$test_name got a response");
    $response = Mojo::JSON::decode_json $t->message->[1];
    $t->json_message_has('/echo_req', "$test_name request echoed");
    $t->json_message_is('/msg_type', $msg_type, "$test_name msg_type is $msg_type");
    return $response;
}

done_testing();