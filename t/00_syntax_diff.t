use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_syntax_on_diff);

# lib/BOM/Test/WebsocketAPI use Devops::BinaryAPI::Tester
# which use Test::Warnings, will fail test due to "Out of Sequence"

my @skip_files = qw(
    lib/BOM/Test/WebsocketAPI
    lib/BOM/Test/Data/Utility/UnitTestMarketData.pm
);

check_syntax_on_diff(@skip_files);

done_testing();
