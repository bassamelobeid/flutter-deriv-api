#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use HTML::Entities;
use Date::Utility;

use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Transaction;
use BOM::Backoffice::PlackHelpers qw(PrintContentType);
use BOM::Backoffice::Request qw(request);

use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

my $loginID         = uc(request()->param('loginID'));
my $encoded_loginID = encode_entities($loginID);

PrintContentType();
BrokerPresentation($encoded_loginID . ' Profit Analysis', '', '');

if ($loginID !~ /^(\D+)(\d+)$/) {
    code_exit_BO("Error: wrong loginID ($encoded_loginID) could not get client instance.");
}

my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginID, db_operation => 'backoffice_replica'}) };

unless ($client) {
    code_exit_BO("Error: wrong loginID ($encoded_loginID) could not get client instance.");
}

my $default_account = $client->default_account;
unless ($default_account) {
    code_exit_BO('Client does not have an account.');
}

my ($startdate) = request()->param('startdate') =~ /(\d{4}-\d{2}-\d{2})/;
my ($enddate)   = request()->param('enddate')   =~ /(\d{4}-\d{2}-\d{2})/;

unless ($startdate && $enddate) {
    code_exit_BO('Invalid date! Please enter date in yyyy-mm-dd format.');
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
        currency      => $client->currency,
        balance       => $profit->{get_close_trades_profit_or_loss} ? $profit->{get_close_trades_profit_or_loss} : '0.00',
        loginid       => $loginID,
        statement_url => request()->url_for(
            'backoffice/f_manager_history.cgi',
            {
                loginID => $loginID,
                broker  => $client->broker,
            }
        ),
        crypto_statement_url => request()->url_for(
            'backoffice/f_manager_crypto_history.cgi',
            {
                loginID => $loginID,
                broker  => $client->broker,
            }
        ),
    },
) || die BOM::Backoffice::Request::template()->error();

code_exit_BO();
