#!/usr/bin/perl
package main;
use strict 'vars';

use f_brokerincludeall;
use Path::Tiny;
use BOM::Platform::Plack qw( PrintContentType );
system_initialize();

my $language = request()->language;
my $show     = request()->param('show');

PrintContentType();
BOM::Platform::Auth0::can_access(['Quants']);

print "<HTML><HEAD><TITLE>File $show</TITLE></HEAD>
        <BODY BGCOLOR=#FFFFFF TEXT=#000000 LINK=#FF0000 VLINK=#800000>
        <CENTER><font size=+2>Show File $show</font>";

if (not -s "$show") {
    print "<P><font color=red>ERROR: the file ($show) does not exist or is of zero size.</P>";
    code_exit_BO();
}

my $show_file = Path::Tiny::path($show);

if (not $show_file->is_file or not -s "$show") {
    print "<P><font color=red>ERROR: ($show) does not exist or is of zero size.</P>";
    code_exit_BO();
}

print "<br><P><FORM ACTION=\"\" METHOD=\"POST\"><B><CENTER>";
print "<textarea name=\"text\" rows=30 cols=80 nowrap wrap=off>";
print $show_file->slurp;
print "</textarea>";
print "</FORM></P>";

code_exit_BO();

