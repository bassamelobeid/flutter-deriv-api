#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use HTML::Entities;
use Format::Util::Strings qw( defang );

use Client::Account;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('CRYTO CASHIER MANAGEMENT');
my $broker           = request()->broker_code;
my $encoded_broker   = encode_entities($broker);
my $staff            = BOM::Backoffice::Auth0::can_access(['Payments']);
my $currency         = defang(request()->param('currency'));
my $action           = defang(request()->param('whattodo'));
my $address          = defang(request()->param('address'));

if (length($broker) < 2) {
    print
        "We cannot process your request because it would seem that your browser is not configured to accept cookies.  Please check that the 'enable cookies' function is set if your browser, then please try again.";
    code_exit_BO();
}

use BOM::Database::ClientDB;

my $clientdb = BOM::Database::ClientDB->new({broker_code => $encoded_broker});
my $dbh = $clientdb->db->dbh;

my $found;
if ($action eq 'verify') {
    ($found) = $dbh->selectrow_array('SELECT payment.ctc_set_withdrawal_verified(?, ?)', undef, $address, $currency);
    # TODO: print warning if not $found
}

if ($action eq 'reject') {
    ($found) = $dbh->selectrow_array('SELECT payment.ctc_set_withdrawal_rejected(?, ?)', undef, $address, $currency);
    # TODO: print warning if not $found
}

my $trxns = $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(?, 'LOCKED'::payment.CTC_STATUS, NULL, NULL)", {Slice => {}}, $currency);

Bar("LIST OF TRANSACTIONS");

my $tt = BOM::Backoffice::Request::template;
$tt->process(
    'backoffice/account/manage_crypto_transactions.tt',
    {
        transactions => $trxns,
        broker       => $broker,
    }) || die $tt->error();

code_exit_BO();
