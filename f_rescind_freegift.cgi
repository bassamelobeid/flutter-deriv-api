#!/usr/bin/perl
package main;
use strict 'vars';

use BOM::Platform::Plack qw( PrintContentType );
use f_brokerincludeall;
use subs::subs_backoffice_removeexpired;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('RESCIND FREE GIFTS');
BOM::Backoffice::Auth0::can_access(['Payments']);
my $clerk  = BOM::Backoffice::Auth0::from_cookie()->{nickname};
my $broker = request()->broker->code;

my $inactivedays = request()->param('inactivedays');
my $whattodo     = request()->param('whattodo');
my $message      = request()->param('message');

if ($inactivedays < 90) {
    print 'Must enter at least 90 days';
    code_exit_BO();
}

print '<p>Starting...</p><pre>';
print "$_<br/>" for Rescind_FreeGifts($broker, $inactivedays, $whattodo, $message, $clerk);
print '</pre><p>...done.</p>';

code_exit_BO();
