use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_syntax_on_diff);

check_syntax_on_diff('lib/BOM/Test/Rudderstack/Webserver.pm');

done_testing();
