#!/usr/bin/perl
package main;

use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use subs::subs_process_moneyness_volsurfaces;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('COMPARISON AMONG MONEYNESS SURFACES');

BOM::Platform::Auth0::can_access(['Quants']);

# Upload Moneyness volsurfaces
my $cgi          = new CGI;
my $filetoupload = $cgi->param('filetoupload');

Bar('Moneyness surface update procedure.');
print compare_uploaded_moneyness_surface($filetoupload);

code_exit_BO();
