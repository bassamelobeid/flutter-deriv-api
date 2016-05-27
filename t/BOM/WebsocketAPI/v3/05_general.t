use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

my $t = build_mojo_test();

$t = $t->send_ok({json => 'notjson'})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{msg_type}, 'error';
is $res->{error}->{code}, 'BadRequest';
ok ref($res->{echo_req}) eq 'HASH';
ok !keys %{$res->{echo_req}};

$t = $t->send_ok({json => {UnrecognisedRequest => 1}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{msg_type}, 'error';
is $res->{error}->{code}, 'UnrecognisedRequest';

$t = $t->send_ok({json => {ping => 1}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{msg_type}, 'ping';
is $res->{ping},     'pong';
test_schema('ping', $res);

$t->finish_ok;

done_testing();
