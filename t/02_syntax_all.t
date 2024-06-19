use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_syntax_all);
$BOM::Test::CheckSyntax::skip_tidy = 1;
my @skip_files = qw(
    lib/BOM/Test/Rudderstack/Webserver.pm
    lib/BOM/Test/WebsocketAPI
    lib/BOM/Test/Data/Utility/UnitTestMarketData.pm
);

check_syntax_all(@skip_files);

done_testing();
