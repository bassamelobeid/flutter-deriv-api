#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use HTML::Entities;

use Date::Utility;
use BOM::User::Client;
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
BrokerPresentation($encoded_loginID . ' Profit Analysis', '', '');

if ($loginID !~ /^(\D+)(\d+)$/) {
    print "Error : wrong loginID ($encoded_loginID) could not get client instance";
    code_exit_BO();
}

my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginID, db_operation => 'replica'}) };

unless ($client) {
    print "Error : wrong loginID ($encoded_loginID) could not get client instance";
    code_exit_BO();
}

my $default_account = $client->default_account;
unless ($default_account) {
    print "Client does not have an account";
    code_exit_BO();
}

my ($startdate) = request()->param('startdate') =~ /(\d{4}-\d{2}-\d{2})/;
my ($enddate)   = request()->param('enddate')   =~ /(\d{4}-\d{2}-\d{2})/;

unless ($startdate && $enddate) {
    print "Invalid date! Please enter date in yyyy-mm-dd format.";
    code_exit_BO();
}

$startdate = Date::Utility->new($startdate);
$enddate   = Date::Utility->new($enddate);

Bar($loginID . " - Profit between " . $startdate->date_yyyymmdd() . " 00:00:00 and " . $enddate->date_yyyymmdd() . " 23:59:59");

my $dbic = BOM::Database::ClientDB->new({
        client_loginid => $client->loginid,
    })->db->dbic;

# Fetch all deposit transactions matching specified currency and status
my $profit = $dbic->run(
    fixup => sub {
        $_->selectrow_hashref(
            "SELECT * FROM get_close_trades_profit_or_loss(?,?,?,?)",
            undef, $default_account->id, $client->currency,
            $startdate->date_yyyymmdd(),
            $enddate->date_yyyymmdd());
    });

BOM::Backoffice::Request::template()->process(
    'backoffice/account/profit_check.html.tt',
    {
        currency => $client->currency,
        balance  => $profit->{get_close_trades_profit_or_loss} ? $profit->{get_close_trades_profit_or_loss} : '0.00',
    },
) || die BOM::Backoffice::Request::template()->error();

code_exit_BO();
