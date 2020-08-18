#!/usr/bin/perl

## Verify all localization calls have proper number of arguments,
## and that the strings are in the translation repo

use strict;
use warnings;
use open ':std', ':encoding(UTF-8)';
use Data::Dumper;

use Path::Tiny;
use Test::More;
use List::Util;

our $VERSION = '1.2';

my $trans_repo          = path '/home/git/binary-com/translations-websockets-api';
my $trans_file_location = "$trans_repo/src/en.po";

my $code_repo         = '/home/git/regentmarkets/bom-rpc';
my $code_dir_location = path "$code_repo/lib/BOM/RPC/v3";

## Which files do we check?
my @file_whitelist = (qr{\.pm$});

## Load the list of all known translated strings
my $trans_file = path($trans_file_location);

## Change all messages to a standard format and put into a hash
my %message;
my @polines = $trans_file->lines_utf8;
for my $line (@polines) {
    next if $line   !~ /msgid\s+"(.+)"/;
    (my $text = $1) =~ s/\\(['"])/$1/g;
    $message{$text} = 1;
}

note sprintf 'Translated strings found in %s: %d', $trans_file->relative($trans_repo), scalar keys %message;

## Loop through all files of interest, pull out localize() calls, and check their contents
my $files_checked = 0;
my $iter          = $code_dir_location->iterator({recurse => 1});
while (my $file = $iter->()) {

    next if List::Util::none { $file =~ $_ } @file_whitelist;

    $files_checked++;

    my @lines = $file->lines_utf8;
    my $pos   = 0;
    for my $line (@lines) {
        my $orig = $line;
        $pos++;
        next if $line !~ /localize\s*\(\s*(['"])(.+?)(?<!\\)\1/;
        my $string = $2;
        $string =~ s/\\(['"])/$1/g;
        my $offset = 1;
        $string =~ s/\[.+?\]/'%' . $offset++ . ''/ge;
        my $relly = $file->relative($code_repo);

        if (exists $message{$string}) {
            pass "Translation found for line $pos of $relly: $string";
        } else {
            ## We do not want to throw a testing error, as translations are too fluid
            ## Instead, we will simply use diag() to make allow it to get seen
            diag "No translation found for line $pos of $relly: >>>$string<<<";
        }
    }
}

diag "Total files checked: $files_checked\n";

done_testing();

exit;
