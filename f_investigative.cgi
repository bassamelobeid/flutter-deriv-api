#!/usr/bin/perl
package main;
use strict 'vars';

use BOM::Platform::Plack qw( PrintContentType );
use Data::Validate::Sanctions qw/is_sanctioned/;
use Path::Tiny;
use f_brokerincludeall;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('INVESTIGATIVE TOOLS');
BOM::Backoffice::Auth0::can_access(['CS']);
my $broker = request()->broker->code;

if (request()->param('whattodo') eq 'unsanctions') {
    Bar('UN Sanctions Query');
    if (is_sanctioned(request()->param('fname'), request()->param('lname'))) {
        print "<b>" . request()->param('fname') . " " . request()->param('lname') . " IS IN THE UN SANCTIONS LIST!!</b>";
    } else {
        print request()->param('fname') . " " . request()->param('lname') . " is not in the sanctions list.";
    }

    code_exit_BO();
}

Bar("ANTI FRAUD TOOLS");

print "<P><LI><B>CLIENT LOGIN HISTORY</B> - A database is maintained of all client login attempts.";
print "<FORM ACTION=\"" . request()->url_for('backoffice/f_viewloginhistory.cgi') . "\" METHOD=POST>";
print "<INPUT type=hidden name=broker value=$broker>";
print "To interrogate this database, input the loginID (or list of loginIDs) :<TEXTAREA name=loginID rows=2 cols=10></TEXTAREA>";
print "<INPUT type=submit value='View Client Login History'>";
print "</FORM>";

print "<P><LI><b>Query UN Sanctions list</b><FORM ACTION=\"" . request()->url_for('backoffice/f_investigative.cgi') . "\" METHOD=POST>";
print "<INPUT type=hidden name=whattodo value=unsanctions>";
print "<INPUT type=hidden name=broker value=$broker>";
print "First name:<INPUT type=text size=15 maxlength=35 name=fname value='Usama'>";
print " Last name:<INPUT type=text size=15 maxlength=35 name=lname value='bin Laden'>";
print "<input type=submit value='Query UN Sanctions Database'>";
print "</form>";

print "</OL>";

Bar("IP related");

print "<FORM ACTION=\"" . request()->url_for('backoffice/ip_search.cgi') . "\" METHOD=POST>";
print "<b>IP SEARCH</b> Enter IP Address : ";
print "<INPUT type=text size=15 maxlength=15 name=ip value='$ENV{'REMOTE_ADDR'}'>";
print "<br>Ignore clients who didn't log in during last <input type=text size=6 value=10 name=lastndays> days ";
print "<input type=submit value='Search for Email'>";
print "</form>";

code_exit_BO();

