#!/etc/rmg/bin/perl
package main;
use strict 'vars';

use HTML::Entities;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Data::Validate::Sanctions;
use Path::Tiny;
use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
use BOM::System::Config;
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('INVESTIGATIVE TOOLS');
BOM::Backoffice::Auth0::can_access(['CS']);
my $broker = request()->broker_code;
my $sanctions = Data::Validate::Sanctions->new(sanction_file => BOM::System::Config::sanction_file);
if (request()->param('whattodo') eq 'unsanctions') {
    Bar('UN Sanctions Query');
    if ($sanctions->is_sanctioned(request()->param('fname'), request()->param('lname'))) {
        print "<b>"
            . encode_entities(request()->param('fname')) . " "
            . encode_entities(request()->param('lname'))
            . " IS IN THE UN SANCTIONS LIST!!</b>";
    } else {
        print encode_entities(request()->param('fname')) . " " . encode_entities(request()->param('lname')) . " is not in the sanctions list.";
    }

    code_exit_BO();
}

Bar("ANTI FRAUD TOOLS");

print "<P><LI><B>USER LOGIN HISTORY</B> - Login history per user (email) login";
print "<FORM ACTION=\"" . request()->url_for('backoffice/f_viewloginhistory.cgi') . "\" METHOD=POST>";
print "Email, or list of emails (space separated) :<TEXTAREA name='email' rows=2 cols=40></TEXTAREA>";
print "<INPUT type=submit value='View User Login History'>";
print "</FORM>";

print "<P><LI><b>Query UN Sanctions list</b><FORM ACTION=\"" . request()->url_for('backoffice/f_investigative.cgi') . "\" METHOD=POST>";
print "<INPUT type=hidden name=whattodo value=unsanctions>";
print "First name:<INPUT type=text size=15 maxlength=35 name=fname value='Usama'>";
print " Last name:<INPUT type=text size=15 maxlength=35 name=lname value='bin Laden'>";
print "<input type=submit value='Query UN Sanctions Database'>";
print "</form>";

print "</OL>";

Bar("IP related");

BOM::Backoffice::Request::template->process(
    'backoffice/ip_search.html.tt',
    {
        ip_search_url => request()->url_for('backoffice/ip_search.cgi'),
        ip            => $ENV{REMOTE_ADDR},
    }) || die BOM::Backoffice::Request::template->error();

code_exit_BO();

