#!/usr/bin/perl
package main;
use strict 'vars';

use BOM::Platform::Plack qw( PrintContentType );
use f_brokerincludeall;
use subs::subs_backoffice_removeexpired;
system_initialize();

PrintContentType();
BrokerPresentation('RESCIND FREE GIFTS');
BOM::Platform::Auth0::can_access(['Payments']);
my $broker = request()->broker->code;

if (BOM::Platform::Runtime->instance->hosts->localhost->canonical_name ne
    BOM::Platform::Runtime->instance->broker_codes->dealing_server_for($broker)->canonical_name)
{
    print "Wrong server for broker code $broker !!";
    code_exit_BO();
}

if (request()->param('inactivedays') < 90) {
    print 'Must enter at least 90 days';
    code_exit_BO();
}

print '<p>Starting...</p><pre>';
map { print $_; } (Rescind_FreeGifts($broker, request()->param('inactivedays'), request()->param('whattodo'), request()->param('message')));
print '</pre><p>...done.</p>';

code_exit_BO();
