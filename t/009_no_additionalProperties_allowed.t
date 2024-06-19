use strict;
use warnings;

use Test::More;
use Test::Warnings;

use Path::Tiny;
use File::Basename;

use JSON;
use List::Util qw(first all);

my $base_path = 'config/v3';
my $dir       = path($base_path);
my $json      = JSON->new;

for ($dir->children) {
    my $request   = basename($_);
    my $send_file = $dir . "/" . $request . "/" . "send.json";

    my $data                 = $json->decode(path($send_file)->slurp_utf8);
    my $additionalProperties = $data->{additionalProperties};

    ok(!$additionalProperties, "$request doesn't allow for additionalProperties");
}

done_testing;
