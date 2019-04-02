#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use subs::subs_backoffice_removeexpired;
use HTML::Entities;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('RESCIND FREE GIFTS');
my $clerk  = BOM::Backoffice::Auth0::get_staffname();
my $broker = request()->broker_code;

my $inactivedays = request()->param('inactivedays');
my $whattodo     = request()->param('whattodo');
my $message      = request()->param('message');

if ($inactivedays < 90) {
    print 'Must enter at least 90 days';
    code_exit_BO();
}

print '<p>Starting...</p><pre>';
print encode_entities($_) . "<br/>" for Rescind_FreeGifts($broker, $inactivedays, $whattodo, $message, $clerk);
print '</pre><p>...done.</p>';

code_exit_BO();
