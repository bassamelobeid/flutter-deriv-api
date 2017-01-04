#!/etc/rmg/bin/perl
package main;
use strict 'vars';
use HTML::Entities;
use f_brokerincludeall;
use Path::Tiny;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

my $language = request()->language;
my $show     = request()->param('show');
my $encoded_show = encode_entities($show);
PrintContentType();
BOM::Backoffice::Auth0::can_access(['Accounts']);

print "<HTML><HEAD><TITLE>File $show</TITLE></HEAD>
        <BODY BGCOLOR=#FFFFFF TEXT=#000000 LINK=#FF0000 VLINK=#800000>
        <CENTER><font size=+2>Show File $encoded_show</font>";

if (not -s "$show") {
    print "<P><font color=red>ERROR: the file ($encoded_show) does not exist or is of zero size.</P>";
    code_exit_BO();
}

my $show_file = Path::Tiny::path($show);

if (not $show_file->is_file or not -s "$show") {
    print "<P><font color=red>ERROR: ($encoded_show) does not exist or is of zero size.</P>";
    code_exit_BO();
}

print "<br><P><FORM ACTION=\"\" METHOD=\"POST\"><B><CENTER>";
print "<textarea name=\"text\" rows=30 cols=80 nowrap wrap=off>";
print encode_entities($show_file->slurp);
print "</textarea>";
print "</FORM></P>";

code_exit_BO();

