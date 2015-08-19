use Test::Most;
use Test::Mojo;
use JSON::Schema;
use JSON;
use File::Slurp;
use File::Basename;

my $svr = $ENV{BOM_WEBSOCKETS_SVR} || '';
my $t   = $svr? Test::Mojo->new: Test::Mojo->new('BOM::WebSocketAPI');

$t->websocket_ok("$svr/websockets/contracts");

my ($test_name, $response);

foreach my $v (grep { -d } glob 'config/v*') {
    explain "Testing version: $v";
    foreach my $f (grep { -d } glob "$v/*") {
        $test_name = File::Basename::basename($f);
        next if ($ENV{TRAVIS} and $f =~ /\/tick$/);
        my $send = strip_doc_send(JSON::from_json(File::Slurp::read_file("$f/send.json")));
        my $response_json = &same_structure_tests($test_name, $send);
        my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/receive.json")));
        my $result = $validator->validate($response_json);
        ok $result, "$f response is valid"; # print " - $_\n" foreach $result->errors;
    }
}

sub strip_doc_send {
    my $data = shift;
    my $r;
    for my $p (keys %{$data->{properties}}) {
        $r->{$p} = $data->{properties}->{$p}->{default};
    }
    return $r;
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