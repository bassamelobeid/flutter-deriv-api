# This script contains a mocked MT5 wrapper command used by the tests in t/BOM/user.t

use strict;
use warnings;

use List::Util qw(pairgrep);
use JSON::MaybeXS;

my %DETAILS_REAL = (
    login => '1000',
    group => 'real\something',
);

my $json = JSON::MaybeXS->new;

my $cmd   = shift @ARGV;
my $input = $json->decode(
    do { local $/; <STDIN> }
);

my $should = $input->{should};

if ($should eq 'fail') {
    print STDERR "FAILING because it should fail\n";
    exit 1;
} else {
    print '{"ok":1}';
    exit 0;
}

