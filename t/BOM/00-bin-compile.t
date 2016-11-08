#!perl
use strict;
use warnings;

use Test::More;
use FindBin;
use File::Basename;
use Path::Tiny;

my $bin_dir = path(dirname($FindBin::Bin))->child('../bin');
my $iter    = $bin_dir->iterator;
while (my $path = $iter->()) {
    next unless $path =~ /\.pl$/;
    note "Checking $path";
    is(system("$^X", "-c", $path), 0, $path->basename . ' compiles OK');
}
done_testing;

