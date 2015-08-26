use strict;
use warnings;
use Test::More;
use Test::Mojo;
use JSON;
use Data::Dumper;

my $t = Test::Mojo->new('BOM::WebSocketAPI');
$t->websocket_ok("/websockets/contracts");

$t = $t->send_ok({json => 'notjson'})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{msg_type}, 'error';
is $res->{error}->{code}, 'BadRequest';

$t = $t->send_ok({json => {UnrecognisedRequest => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{msg_type}, 'error';
is $res->{error}->{code}, 'UnrecognisedRequest';

$t = $t->send_ok({json => {ping => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{msg_type}, 'ping';
is $res->{ping},     'pong';

$t->finish_ok;

done_testing();
