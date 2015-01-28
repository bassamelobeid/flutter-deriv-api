#!/usr/bin/perl
package main;
use strict 'vars';

use BOM::Utility::Date;
use BOM::Platform::Client;
use BOM::Platform::Data::Persistence::ConnectionBuilder;
use BOM::Platform::Data::Persistence::DataMapper::Transaction;
use BOM::Platform::Plack qw( PrintContentType );

use f_brokerincludeall;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

my $loginID = uc(request()->param('loginID'));

PrintContentType();
BrokerPresentation($loginID . ' Profit Analysis', '', '');
BOM::Platform::Auth0::can_access(['CS']);

if ($loginID !~ /^(\D+)(\d+)$/) {
    print "Error : wrong loginID ($loginID) could not get client instance";
    code_exit_BO();
}

my $client = BOM::Platform::Client::get_instance({'loginid' => $loginID});
if (not $client) {
    print "Error : wrong loginID ($loginID) could not get client instance";
    code_exit_BO();
}

my $startdate = request()->param('startdate');
my $enddate   = request()->param('enddate');

$startdate = BOM::Utility::Date->new($startdate);
$enddate   = BOM::Utility::Date->new($enddate);

my $db = BOM::Platform::Data::Persistence::ConnectionBuilder->new({
        client_loginid => $client->loginid,
            })->db;

Bar($loginID . " - Profit between " . $startdate->datetime . " and " . $enddate->datetime);

my $txn_dm = BOM::Platform::Data::Persistence::DataMapper::Transaction->new({
    client_loginid => $client->loginid,
    currency_code  => $client->currency,
    db             => $db,
});

my $balance = $txn_dm->get_profit_for_days({
    after  => $startdate->datetime,
    before => $enddate->datetime
});

BOM::Platform::Context::template->process(
    'backoffice/account/profit_check.html.tt',
    {
        currency => $client->currency,
        balance  => $balance,
    },
) || die BOM::Platform::Context::template->error();

code_exit_BO();
