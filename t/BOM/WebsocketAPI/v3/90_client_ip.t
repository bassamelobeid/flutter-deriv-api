use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/build_mojo_test/;
use Test::MockModule;
use Clone;

my $valid_client_ip = '98.1.1.1';

my $websapi = Test::MockModule->new('BOM::WebSocketAPI::Websocket_v3');
$websapi->mock('rpc', sub { $_[0]->send({json => $_[3]}); });

my ($t, $res);

$t = build_mojo_test({language => 'RU'}, {'x-forwarded-for' => "some text, $valid_client_ip"});
$t = $t->send_ok({json => {logout => 1}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{client_ip}, $valid_client_ip, 'Should send valid ipv4 to RPC getting from header';
is $res->{language}, 'RU', 'Should send language';

$t->finish_ok;

done_testing();
