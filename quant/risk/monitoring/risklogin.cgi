#!/usr/bin/perl
package main;
use strict 'vars';
use BOM::Utility::Format::Numbers qw(virgule);

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Market::UnderlyingDB;
system_initialize();

PrintContentType();
BrokerPresentation('MONITORING');
BOM::Platform::Auth0::can_access(['Quants']);

Bar('Risk Dashboard.');
print '<h1><a id="risk_monitoring" href="' . request()->url_for('backoffice/quant/risk_dashboard.cgi') . '">Get it here.</a></h1>';

code_exit_BO();

