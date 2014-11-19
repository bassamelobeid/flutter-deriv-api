#!/usr/bin/perl
package main;

use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use subs::subs_process_moneyness_volsurfaces;
use BOM::Platform::Plack qw( PrintContentType );

system_initialize();
PrintContentType();
BrokerPresentation('COMPARISON AMONG MONEYNESS SURFACES');

BOM::Platform::Auth0::can_access(['Quants']);

# Upload Moneyness volsurfaces
my $cgi          = new CGI;
my $filetoupload = $cgi->param('filetoupload');

my ($surfaces, $filename) = upload_and_process_moneyness_volsurfaces($filetoupload);

Bar('Moneyness surface update procedure.');
print compare_uploaded_moneyness_surface($surfaces);

unlink $filename;

code_exit_BO();
