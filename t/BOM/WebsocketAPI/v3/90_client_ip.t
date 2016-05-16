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

my $websapi = Test::MockModule->new('BOM::WebSocketAPI::CallingEngine');
$websapi->mock('call_rpc', sub { shift->send({json => shift->{call_params}}) });

my ($t, $res);

$t = build_mojo_test({language => 'RU'}, {'x-forwarded-for' => "some text, $valid_client_ip"});
$t = $t->send_ok({json => {logout => 1}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{client_ip}, $valid_client_ip, 'Should send valid ipv4 to RPC getting from header';
is $res->{language}, 'RU', 'Should send language';

$t->finish_ok;

done_testing();
