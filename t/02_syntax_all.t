use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_syntax_all);
my @skip_files = qw(
    lib/BOM/Test/Script
    lib/BOM/Test/WebsocketAPI
    lib/BOM/Test.pm
    lib/BOM/Test/Localize.pm
    lib/BOM/Test/Helper.pm
    lib/BOM/Test/Email.pm
    lib/BOM/Test/Helper/CTC.pm
    lib/BOM/Test/Suite/DSL.pm
    lib/BOM/Test/Suite.pm
    lib/BOM/Test/Contract.pm
    lib/BOM/Test/Initializations.pm
    lib/BOM/Test/App/WebSocket.pm
    lib/BOM/Test/RPC/BinaryRpcRedis.pm
    lib/BOM/Test/Rudderstack/Webserver.pm
    lib/BOM/Test/Data/Utility/UnitTestMarketData.pm
);

check_syntax_all(@skip_files);

done_testing();
