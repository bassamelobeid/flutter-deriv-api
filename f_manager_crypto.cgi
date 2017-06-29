#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use HTML::Entities;

use Client::Account;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('CRYTO CASHIER MANAGEMENT');
my $broker         = request()->broker_code;
my $encoded_broker = encode_entities($broker);
my $staff          = BOM::Backoffice::Auth0::can_access(['Payments']);
my $currency       = request()->param('currency');
my $action         = request()->param('action');
my $address        = request()->param('address');
my $view_type      = request()->param('view_type') // 'pending';

if (length($broker) < 2) {
    print
        "We cannot process your request because it would seem that your browser is not configured to accept cookies.  Please check that the 'enable cookies' function is set if your browser, then please try again.";
    code_exit_BO();
}

if (not $currency or $currency !~ /^[A-Z]{3}$/) {
    print "Invalid currency.";
    code_exit_BO();
}

if ($address and $address !~ /^\w+$/) {
    print "Invalid address.";
    code_exit_BO();
}

if ($action and $action !~ /^[a-zA-Z]{4,15}$/) {
    print "Invalid action.";
    code_exit_BO();
}

if (not $view_type or $view_type !~ /^(?:pending|verified|rejected|sent|error)$/) {
    print "Invalid selection to view type of transactions.";
    code_exit_BO();
}

use BOM::Database::ClientDB;
my $clientdb = BOM::Database::ClientDB->new({broker_code => $encoded_broker});
my $dbh = $clientdb->db->dbh;

my $found;
if ($action and $action eq 'verify') {
    ($found) = $dbh->selectrow_array('SELECT payment.ctc_set_withdrawal_verified(?, ?)', undef, $address, $currency);
    unless ($found) {
        print "ERROR: No record found. Please check with someone from IT team before proceeding.";
        code_exit_BO();
    }
}

if ($action and $action eq 'reject') {
    ($found) = $dbh->selectrow_array('SELECT payment.ctc_set_withdrawal_rejected(?, ?)', undef, $address, $currency);
    unless ($found) {
        print "ERROR: No record found. Please check with someone from IT team before proceeding.";
        code_exit_BO();
    }
}

my $trxns;
if ($view_type eq 'sent') {
    $trxns =
        $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(?, 'SENT'::payment.CTC_STATUS, NULL, NULL)", {Slice => {}}, $currency);
} elsif ($view_type eq 'verified') {
    $trxns = $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(?, 'VERIFIED'::payment.CTC_STATUS, NULL, NULL)",
        {Slice => {}}, $currency);
} elsif ($view_type eq 'rejected') {
    $trxns = $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(?, 'REJECTED'::payment.CTC_STATUS, NULL, NULL)",
        {Slice => {}}, $currency);
} elsif ($view_type eq 'error') {
    $trxns =
        $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(?, 'ERROR'::payment.CTC_STATUS, NULL, NULL)", {Slice => {}}, $currency);
} else {
    $trxns =
        $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(?, 'LOCKED'::payment.CTC_STATUS, NULL, NULL)", {Slice => {}},
        $currency);
}

Bar("LIST OF TRANSACTIONS - WITHDRAWAL");

my $tt = BOM::Backoffice::Request::template;
$tt->process(
    'backoffice/account/manage_crypto_transactions.tt',
    {
        transactions => $trxns,
        broker       => $broker,
        view_type    => $view_type,
        currency     => $currency,
    }) || die $tt->error();

code_exit_BO();
