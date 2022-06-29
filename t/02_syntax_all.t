use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_syntax_all);
my @skip_files = qw(
    lib/BOM/Test/Rudderstack/Webserver.pm
    lib/BOM/Test/WebsocketAPI
);

check_syntax_all(@skip_files);

done_testing();
