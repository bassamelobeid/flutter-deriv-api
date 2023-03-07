use strict;
use warnings;

use Test::More;
use Test::Warnings;

use Path::Tiny;
use File::Basename;

my $base_path = 'config/v3';
my $dir       = path($base_path);

for ($dir->children) {
    my $request = basename($_);

    # Grep for usage
    my $grep = 'grep -r "\"' . $request . '\"" ' . "$base_path/* | grep 'send.json' | grep -v '$request/send.json' | grep {";

    my $usage = `$grep`;

    if ($request eq 'landing_company') {
        ok($usage, "landing_company is expected to return multiple usage");
    } else {
        ok !$usage, "$request is ok";
    }
}

done_testing;
