#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use BOM::Backoffice::PlackHelpers qw/PrintContentType_excel PrintContentType/;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Utility;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('EMAIL FORMS');

my $tt = BOM::Backoffice::Request::template;

Bar('ACCOUNT RECOVERY EMAIL');

$tt->process('backoffice/newpassword_email.html.tt', {languages => BOM::Backoffice::Utility::get_languages()}) || die $tt->error();

Bar('JAPAN SPECIFIC EMAILS');

$tt->process('backoffice/japan/payment_email_form.html.tt') || die $tt->error();

code_exit_BO();
