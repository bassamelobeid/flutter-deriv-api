use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_syntax_on_diff);
my @skip_files = qw(
	lib/BOM/Test/WebsocketAPI.pm
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

check_syntax_on_diff(@skip_files);

done_testing();
