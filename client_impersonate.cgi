#!/usr/bin/perl
package main;

use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::Auth0;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();

BrokerPresentation('Client Impersonate');
BOM::Backoffice::Auth0::can_access(['CS']);

Bar('Client Impersonate');

my $login  = request()->param('impersonate_loginid');
my $broker = request()->broker->code;

if ($login !~ /^$broker\d+$/) {
    print 'ERROR : Wrong loginID ' . $login;
    code_exit_BO();
}

my $client = BOM::Platform::Client::get_instance({'loginid' => $login});
if (not $client) {
    print "Error : wrong loginID ($loginid) could not get client instance";
    code_exit_BO();
}
