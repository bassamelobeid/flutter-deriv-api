use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_syntax_on_diff);

my @skip_files = ('lib/CSVParser/Merlin.pm');

check_syntax_on_diff(@skip_files);

done_testing();
