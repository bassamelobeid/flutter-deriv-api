#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::RiskReporting::Client;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw/PrintContentType_XSendfile/;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

my $clerk = BOM::Backoffice::Auth0::from_cookie()->{nickname};

my $loginid = request()->param('loginid') || '';
my $action  = request()->param('action')  || '';

my ($data, $error);
if ($action && !$loginid) {
    $error = "Missing loginid";
} elsif ($action eq 'export') {
    $data = BOM::RiskReporting::Client->new({loginid => $loginid})->get;
    my $file = BOM::RiskReporting::Client::export($data, $loginid);
    PrintContentType_XSendfile($file, 'application/octet-stream', "$loginid.xlsx");
    code_exit_BO();
} elsif ($action eq 'only add comment') {
    $data = BOM::RiskReporting::Client->new({loginid => $loginid})->add_comment($clerk, request()->param('comment'));
} elsif ($action eq 'generate report') {
    $data = BOM::RiskReporting::Client->new({loginid => $loginid})->generate($clerk, request()->param('comment'));
} elsif ($loginid) {
    $data = BOM::RiskReporting::Client->new({loginid => $loginid})->get;
}

PrintContentType();
BrokerPresentation('Show Risk Report For: ' . $loginid);
BOM::Backoffice::Request::template->process(
    'backoffice/client_risk.html.tt',
    {
        loginid => $loginid,
        data    => $data,
        error   => $error,
    },
) || die BOM::Backoffice::Request::template->error();

code_exit_BO();
