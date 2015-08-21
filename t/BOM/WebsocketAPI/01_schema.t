use Test::Most;
use Test::Mojo;
use JSON::Schema;
use JSON;
use File::Slurp;
use File::Basename;

my $svr = $ENV{BOM_WEBSOCKETS_SVR} || '';
my $t = $svr ? Test::Mojo->new : Test::Mojo->new('BOM::WebSocketAPI');

$t->websocket_ok("$svr/websockets/contracts");

my ($test_name, $response);

foreach my $v (grep { -d } glob 'config/v*') {
    explain "Testing version: $v";
    foreach my $f (grep { -d } glob "$v/*") {
        $test_name = File::Basename::basename($f);
        next if ($ENV{TRAVIS} and $f =~ /\/ticks?$/);
        my $send = strip_doc_send(JSON::from_json(File::Slurp::read_file("$f/send.json")));
        $t->send_ok({json => $send}, "send request for $test_name");
        $t->message_ok("$test_name got a response");
        my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/receive.json")));
        my $result    = $validator->validate(Mojo::JSON::decode_json $t->message->[1]);
        ok $result, "$f response is valid";    # print " - $_\n" foreach $result->errors;
    }
}

sub strip_doc_send {
    my $data = shift;
    my $r;
    for my $p (keys %{$data->{properties}}) {
        $r->{$p} = $data->{properties}->{$p}->{default} // {};
    }
    return $r;
}

done_testing();
