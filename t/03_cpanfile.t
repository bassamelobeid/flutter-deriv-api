use strict;
use warnings;

use Test::More;
use Text::Diff;

my $versions = `make versions`;
$versions = (join qq{\n} => grep { !/^make/ } split qq{\n} => $versions) . qq{\n};
my $diff = diff './cpanfile', \$versions;

ok(!$diff, 'Cpanfile is up to date. (If failed, pull latest changes to cpan and cpan-private repos and run make update_cpanfile)');

warn $diff if $diff;

done_testing();
