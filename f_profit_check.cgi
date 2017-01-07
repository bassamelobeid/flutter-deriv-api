#!/etc/rmg/bin/perl
package main;
use strict 'vars';
use HTML::Entities;

use Date::Utility;
use Client::Account;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Transaction;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);

use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

my $loginID         = uc(request()->param('loginID'));
my $encoded_loginID = encode_entities($loginID);
PrintContentType();
BrokerPresentation($loginID . ' Profit Analysis', '', '');
BOM::Backoffice::Auth0::can_access(['CS']);

if ($loginID !~ /^(\D+)(\d+)$/) {
    print "Error : wrong loginID ($encoded_loginID) could not get client instance";
    code_exit_BO();
}

my $client = Client::Account::get_instance({'loginid' => $loginID});
if (not $client) {
    print "Error : wrong loginID ($encoded_loginID) could not get client instance";
    code_exit_BO();
}

my $startdate = request()->param('startdate');
my $enddate   = request()->param('enddate');

$startdate = Date::Utility->new($startdate);
$enddate   = Date::Utility->new($enddate);

my $db = BOM::Database::ClientDB->new({
        client_loginid => $client->loginid,
    })->db;

Bar($encoded_loginID . " - Profit between " . $startdate->datetime . " and " . $enddate->datetime);

my $txn_dm = BOM::Database::DataMapper::Transaction->new({
    client_loginid => $client->loginid,
    currency_code  => $client->currency,
    db             => $db,
});

my $balance = $txn_dm->get_profit_for_days({
    after  => $startdate->datetime,
    before => $enddate->datetime
});

BOM::Backoffice::Request::template->process(
    'backoffice/account/profit_check.html.tt',
    {
        currency => $client->currency,
        balance  => $balance,
    },
) || die BOM::Backoffice::Request::template->error();

code_exit_BO();
