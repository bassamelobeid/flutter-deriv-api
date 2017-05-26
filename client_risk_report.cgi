#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::RiskReporting::Client;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

BOM::Backoffice::Auth0::can_access(['Compliance']);
my $clerk = BOM::Backoffice::Auth0::from_cookie()->{nickname};

my $loginid = request()->param('loginid') || '';
my $action  = request()->param('action')  || '';
BrokerPresentation('Show Risk Report For: ' . $loginid);

if ($action && !$loginid) {
    print "Missing loginid";
}

my $data;
if ($action eq 'only add comment') {
    $data = BOM::RiskReporting::Client->new({loginid => $loginid})->add_comment($clerk, request()->param('comment'));
} elsif ($action eq 'generate report') {
    $data = BOM::RiskReporting::Client->new({loginid => $loginid})->generate($clerk, request()->param('comment'));
} elsif ($loginid) {
    $data = BOM::RiskReporting::Client->new({loginid => $loginid})->get;
}

BOM::Backoffice::Request::template->process(
    'backoffice/client_risk.html.tt',
    {
        loginid => $loginid,
        data    => $data,
    },
) || die BOM::Backoffice::Request::template->error();

code_exit_BO();
