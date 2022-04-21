use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_syntax_on_diff check_syntax_all);
my @skip_files = qw(
	lib/BOM/Test.pm
	lib/BOM/Test/Email.pm
	lib/BOM/Test/Contract.pm
	lib/BOM/Test/WebsocketAPI.pm
	lib/BOM/Test/Initializations.pm
	lib/BOM/Test/App/WebSocket.pm
	lib/BOM/Test/RPC/BinaryRpcRedis.pm
	lib/BOM/Test/Rudderstack/Webserver.pm
	lib/BOM/Test/Script/NotifyPub.pm
	lib/BOM/Test/Script/PricerQueue.pm
	lib/BOM/Test/Script/DevExperts.pm
	lib/BOM/Test/Script/RpcRedis.pm
	lib/BOM/Test/Script/PricerDaemon.pm
	lib/BOM/Test/Script/OnfidoMock.pm
	lib/BOM/Test/Script/ExperianMock.pm
);

check_syntax_all(@skip_files);

done_testing();
