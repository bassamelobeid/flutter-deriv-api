use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_syntax_on_diff);
my @skip_files = qw(
    lib/BOM/Test/WebsocketAPI
    lib/BOM/Test/Rudderstack/Webserver.pm
);

check_syntax_on_diff();

done_testing();
